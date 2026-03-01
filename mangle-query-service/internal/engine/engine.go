// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
// Package engine wraps the Mangle Datalog interpreter for query resolution.
package engine

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"

	"strings"

	"github.com/google/mangle/analysis"
	"github.com/google/mangle/ast"
	mangleEngine "github.com/google/mangle/engine"
	"github.com/google/mangle/factstore"
	"github.com/google/mangle/interpreter"
	"github.com/google/mangle/parse"
)

// Resolution holds the result of a Mangle query evaluation.
type Resolution struct {
	Answer     string
	Path       string
	Confidence float64
	Sources    []Source
}

// Source represents a knowledge source used during resolution.
type Source struct {
	Title   string
	Content string
	Origin  string
	Score   float64
}

// MangleEngine wraps the Mangle Datalog interpreter.
type MangleEngine struct {
	mu       sync.RWMutex
	interp   *interpreter.Interpreter
	rulesDir string
	// rulesContent caches the raw content of the rules file so it can be
	// combined with dynamic facts in a single Define call.
	rulesContent string
	// facts holds ground facts that are defined before rules are loaded.
	facts []string
	// External predicates for production use (ES, MCP, etc.)
	extPredicates map[ast.PredicateSym]mangleEngine.ExternalPredicateCallback
	// store and programInfo for engine-direct mode (when external predicates are used)
	store       factstore.FactStoreWithRemove
	programInfo *analysis.ProgramInfo
}

// New creates a new MangleEngine, loading rules from the given directory.
// Only routing.mg is loaded; use NewWithRules to load additional rule files.
func New(rulesDir string) (*MangleEngine, error) {
	return NewWithRules(rulesDir, "routing.mg")
}

// NewWithRules creates a MangleEngine loading the specified rule files (relative
// to rulesDir) concatenated in order.  This is used by tests that need
// governance.mg or rag_enrichment.mg in addition to routing.mg.
func NewWithRules(rulesDir string, ruleFiles ...string) (*MangleEngine, error) {
	eng := &MangleEngine{
		rulesDir:      rulesDir,
		extPredicates: make(map[ast.PredicateSym]mangleEngine.ExternalPredicateCallback),
	}

	var combined strings.Builder
	for _, f := range ruleFiles {
		rulesPath := filepath.Join(rulesDir, f)
		content, err := os.ReadFile(rulesPath)
		if err != nil {
			return nil, fmt.Errorf("failed to read rules file %s: %w", rulesPath, err)
		}
		combined.Write(content)
		combined.WriteByte('\n')
	}
	eng.rulesContent = combined.String()

	if err := eng.reload(); err != nil {
		return nil, fmt.Errorf("failed to load rules: %w", err)
	}
	return eng, nil
}

// RegisterPredicate adds an external predicate callback. Must be called
// before DefineFact or Resolve. Call Reload after registering all predicates.
func (e *MangleEngine) RegisterPredicate(name string, arity int, cb mangleEngine.ExternalPredicateCallback) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.extPredicates[ast.PredicateSym{Symbol: name, Arity: arity}] = cb
}

// Reload re-parses rules and re-evaluates with current facts and predicates.
func (e *MangleEngine) Reload() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.reload()
}

func (e *MangleEngine) reload() error {
	if len(e.extPredicates) > 0 {
		return e.reloadWithEngine()
	}
	return e.reloadWithInterpreter()
}

// reloadWithInterpreter uses the Mangle interpreter (for tests with DefineFact).
func (e *MangleEngine) reloadWithInterpreter() error {
	e.interp = interpreter.New(io.Discard, e.rulesDir, nil)

	combined := ""
	for _, fact := range e.facts {
		combined += fact + "\n"
	}
	combined += e.rulesContent

	if err := e.interp.Define(combined); err != nil {
		return fmt.Errorf("failed to define facts and rules: %w", err)
	}
	return nil
}

// reloadWithEngine uses the Mangle engine directly (supports external predicates).
func (e *MangleEngine) reloadWithEngine() error {
	combined := ""
	for _, fact := range e.facts {
		combined += fact + "\n"
	}
	combined += e.rulesContent

	unit, err := parse.Unit(strings.NewReader(combined))
	if err != nil {
		return fmt.Errorf("failed to parse rules: %w", err)
	}

	// Build known predicates from external predicate registrations.
	knownPredicates := make(map[ast.PredicateSym]ast.Decl)
	for sym := range e.extPredicates {
		knownPredicates[sym] = ast.Decl{DeclaredAtom: ast.NewAtom(sym.Symbol)}
	}

	programInfo, err := analysis.AnalyzeOneUnit(unit, knownPredicates)
	if err != nil {
		return fmt.Errorf("failed to analyze rules: %w", err)
	}

	e.store = factstore.NewSimpleInMemoryStore()
	e.programInfo = programInfo

	if err := mangleEngine.EvalProgram(programInfo, e.store,
		mangleEngine.WithExternalPredicates(e.extPredicates)); err != nil {
		return fmt.Errorf("failed to evaluate rules: %w", err)
	}

	// Also set up interpreter for Query support
	e.interp = interpreter.New(io.Discard, e.rulesDir, nil)
	if err := e.interp.Define(combined); err != nil {
		// Non-fatal: query may still work through store
		_ = err
	}

	return nil
}

// DefineFact adds a ground fact and re-evaluates all rules so that
// derived predicates reflect the new fact.
func (e *MangleEngine) DefineFact(clauseText string) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	e.facts = append(e.facts, clauseText)
	return e.reload()
}

// Resolve evaluates the resolve/4 predicate for the given query string.
func (e *MangleEngine) Resolve(query string) (*Resolution, error) {
	e.mu.RLock()
	defer e.mu.RUnlock()

	atom, err := parse.Atom(fmt.Sprintf(`resolve(%q, Answer, Path, Score)`, query))
	if err != nil {
		return nil, fmt.Errorf("failed to parse query atom: %w", err)
	}

	results, err := e.interp.Query(atom)
	if err != nil {
		return nil, fmt.Errorf("mangle evaluation failed: %w", err)
	}

	if len(results) == 0 {
		return &Resolution{Path: "no_match", Confidence: 0}, nil
	}

	res := &Resolution{}
	for _, term := range results {
		if a, ok := term.(ast.Atom); ok {
			args := a.Args
			if len(args) >= 4 {
				res.Answer = extractString(args[1])
				res.Path = extractString(args[2])
				res.Confidence = extractFloat(args[3])
			}
		}
	}
	return res, nil
}

func extractString(t ast.BaseTerm) string {
	if c, ok := t.(ast.Constant); ok {
		if s, err := c.StringValue(); err == nil {
			return s
		}
	}
	return ""
}

func extractFloat(t ast.BaseTerm) float64 {
	if c, ok := t.(ast.Constant); ok {
		if f, err := c.Float64Value(); err == nil {
			return f
		}
		if n, err := c.NumberValue(); err == nil {
			return float64(n)
		}
	}
	return 0
}
