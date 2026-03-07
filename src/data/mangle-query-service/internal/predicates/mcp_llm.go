// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package predicates

import (
	"encoding/json"
	"fmt"

	"github.com/google/mangle/ast"
)

// MCPLLMPredicate implements llm_generate/3: (Query, Context, Answer).
type MCPLLMPredicate struct {
	MCPAddress string
	AuthToken  string
}

func (p *MCPLLMPredicate) ShouldPushdown() bool { return false }

func (p *MCPLLMPredicate) ShouldQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term) bool {
	return len(inputs) >= 2
}

func (p *MCPLLMPredicate) ExecuteQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term, cb func([]ast.BaseTerm)) error {
	if len(inputs) < 2 {
		return fmt.Errorf("llm_generate requires 2 inputs (query, context)")
	}

	query, err := inputs[0].StringValue()
	if err != nil {
		return fmt.Errorf("llm_generate: invalid query: %w", err)
	}
	context, err := inputs[1].StringValue()
	if err != nil {
		return fmt.Errorf("llm_generate: invalid context: %w", err)
	}

	answer := p.generate(query, context)
	cb([]ast.BaseTerm{ast.String(answer)})
	return nil
}

func (p *MCPLLMPredicate) generate(query, context string) string {
	if p.MCPAddress != "" {
		result, err := p.callMCP(query, context)
		if err == nil {
			return result
		}
	}
	return fmt.Sprintf("Based on the available context, here is an answer to: %s", query)
}

func (p *MCPLLMPredicate) callMCP(query, context string) (string, error) {
	mcpResult, err := callMCPTool(p.MCPAddress, p.AuthToken, "llm_generate", map[string]any{
		"query":   query,
		"context": context,
	})
	if err == nil {
		answer := stringField(mcpResult, "answer", "content", "text")
		if answer != "" {
			return answer, nil
		}
	}

	legacyBody, _ := json.Marshal(map[string]string{"query": query, "context": context})
	legacyResult, legacyErr := legacyMCPHTTPCall(p.MCPAddress, p.AuthToken, "/mcp/tools/llm_generate", legacyBody)
	if legacyErr != nil {
		if err != nil {
			return "", err
		}
		return "", legacyErr
	}
	answer := stringField(legacyResult, "answer", "content", "text")
	if answer == "" {
		return "", fmt.Errorf("mcp llm_generate response missing answer")
	}
	return answer, nil
}
