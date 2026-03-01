// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package predicates

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/google/mangle/ast"
)

// MCPClassifyPredicate implements classify_query/3: (Query, Category, Confidence).
// Calls an MCP server or uses heuristic fallback.
type MCPClassifyPredicate struct {
	MCPAddress string // e.g. "http://localhost:8001"
	AuthToken  string
}

func (p *MCPClassifyPredicate) ShouldPushdown() bool { return false }

func (p *MCPClassifyPredicate) ShouldQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term) bool {
	return len(inputs) > 0
}

func (p *MCPClassifyPredicate) ExecuteQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term, cb func([]ast.BaseTerm)) error {
	if len(inputs) == 0 {
		return fmt.Errorf("classify_query requires 1 input (query)")
	}

	query, err := inputs[0].StringValue()
	if err != nil {
		return fmt.Errorf("classify_query: invalid query: %w", err)
	}

	category, confidence := p.classify(query)

	// Convert confidence to 0-100 integer
	score := int64(confidence * 100)
	cb([]ast.BaseTerm{
		ast.String(category),
		ast.Number(score),
	})
	return nil
}

func (p *MCPClassifyPredicate) classify(query string) (string, float64) {
	if p.MCPAddress != "" {
		cat, conf, err := p.callMCP(query)
		if err == nil {
			return cat, conf
		}
		// Fall through to heuristic on MCP failure
	}
	return heuristicClassify(query)
}

func (p *MCPClassifyPredicate) callMCP(query string) (string, float64, error) {
	mcpResult, err := callMCPTool(p.MCPAddress, p.AuthToken, "classify_query", map[string]any{
		"query": query,
	})
	if err == nil {
		category := stringField(mcpResult, "category", "class", "label")
		confidence := floatField(mcpResult, "confidence", "score")
		if category != "" {
			if confidence == 0 {
				confidence = 0.8
			}
			return category, confidence, nil
		}
	}

	legacyBody, _ := json.Marshal(map[string]string{"query": query})
	legacyResult, legacyErr := legacyMCPHTTPCall(p.MCPAddress, p.AuthToken, "/mcp/tools/classify_query", legacyBody)
	if legacyErr != nil {
		if err != nil {
			return "", 0, err
		}
		return "", 0, legacyErr
	}
	category := stringField(legacyResult, "category", "class", "label")
	confidence := floatField(legacyResult, "confidence", "score")
	if category == "" {
		return "", 0, fmt.Errorf("mcp classify response missing category")
	}
	if confidence == 0 {
		confidence = 0.8
	}
	return category, confidence, nil
}

func heuristicClassify(query string) (string, float64) {
	q := strings.ToLower(query)

	factualPatterns := []string{"show me", "find", "get", "lookup", "order", "customer", "product"}
	for _, p := range factualPatterns {
		if strings.Contains(q, p) {
			return "FACTUAL", 0.8
		}
	}

	ragPatterns := []string{"how to", "configure", "setup", "guide", "documentation", "steps"}
	for _, p := range ragPatterns {
		if strings.Contains(q, p) {
			return "RAG_RETRIEVAL", 0.8
		}
	}

	llmPatterns := []string{"why", "compare", "analyze", "trend", "predict", "recommend"}
	for _, p := range llmPatterns {
		if strings.Contains(q, p) {
			return "LLM_REQUIRED", 0.8
		}
	}

	return "RAG_RETRIEVAL", 0.5
}
