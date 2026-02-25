package engine

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"

	"github.com/google/mangle/ast"
	"github.com/google/mangle/interpreter"
	"github.com/google/mangle/parse"
)

// Resolution holds the result of a Mangle rule evaluation.
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
}

// New creates a new MangleEngine, loading rules from the given directory.
func New(rulesDir string) (*MangleEngine, error) {
	eng := &MangleEngine{
		rulesDir: rulesDir,
	}

	// Read and cache the rules file content.
	rulesPath := filepath.Join(rulesDir, "routing.mg")
	content, err := os.ReadFile(rulesPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read rules file %s: %w", rulesPath, err)
	}
	eng.rulesContent = string(content)

	if err := eng.reload(); err != nil {
		return nil, fmt.Errorf("failed to load rules: %w", err)
	}
	return eng, nil
}

// reload creates a fresh interpreter and loads all facts and rules together
// in a single Define call so that bottom-up evaluation derives all
// intensional predicates from the current set of facts.
func (e *MangleEngine) reload() error {
	e.interp = interpreter.New(io.Discard, e.rulesDir, nil)

	// Build a combined source: facts first, then rules.
	// This ensures the facts are present when rules are evaluated.
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

	// Extract first result -- Query returns []ast.Term, each being an ast.Atom.
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
		// Try int64 conversion
		if n, err := c.NumberValue(); err == nil {
			return float64(n)
		}
	}
	return 0
}
