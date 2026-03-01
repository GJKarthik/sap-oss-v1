// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package predicates

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/google/mangle/ast"
)

// MCPRerankPredicate implements rerank/3: (Query, DocsIn, DocsOut).
type MCPRerankPredicate struct {
	MCPAddress string
	AuthToken  string
}

func (p *MCPRerankPredicate) ShouldPushdown() bool { return false }

func (p *MCPRerankPredicate) ShouldQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term) bool {
	return len(inputs) >= 2
}

func (p *MCPRerankPredicate) ExecuteQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term, cb func([]ast.BaseTerm)) error {
	if len(inputs) < 2 {
		return fmt.Errorf("rerank requires 2 inputs (query, documents)")
	}

	query, err := inputs[0].StringValue()
	if err != nil {
		return fmt.Errorf("rerank: invalid query: %w", err)
	}
	docsJSON, err := inputs[1].StringValue()
	if err != nil {
		return fmt.Errorf("rerank: invalid documents: %w", err)
	}

	reranked := p.rerank(query, docsJSON)
	cb([]ast.BaseTerm{ast.String(reranked)})
	return nil
}

func (p *MCPRerankPredicate) rerank(query, docsJSON string) string {
	if p.MCPAddress != "" {
		result, err := p.callMCP(query, docsJSON)
		if err == nil {
			return result
		}
	}
	return heuristicRerank(query, docsJSON)
}

func (p *MCPRerankPredicate) callMCP(query, docsJSON string) (string, error) {
	mcpResult, err := callMCPTool(p.MCPAddress, p.AuthToken, "rerank", map[string]any{
		"query":     query,
		"documents": docsJSON,
	})
	if err == nil {
		documents := stringField(mcpResult, "documents", "reranked_documents")
		if documents != "" {
			return documents, nil
		}
		if results, ok := mcpResult["results"].([]any); ok {
			out, marshalErr := json.Marshal(results)
			if marshalErr == nil {
				return string(out), nil
			}
		}
	}

	legacyBody, _ := json.Marshal(map[string]string{"query": query, "documents": docsJSON})
	legacyResult, legacyErr := legacyMCPHTTPCall(p.MCPAddress, p.AuthToken, "/mcp/tools/rerank", legacyBody)
	if legacyErr != nil {
		if err != nil {
			return "", err
		}
		return "", legacyErr
	}
	documents := stringField(legacyResult, "documents", "reranked_documents")
	if documents == "" {
		return "", fmt.Errorf("mcp rerank response missing documents")
	}
	return documents, nil
}

type rerankDoc struct {
	Content string  `json:"content"`
	Title   string  `json:"title,omitempty"`
	Source  string  `json:"source,omitempty"`
	Score   float64 `json:"score,omitempty"`
}

func heuristicRerank(query, docsJSON string) string {
	var docs []rerankDoc
	if err := json.Unmarshal([]byte(docsJSON), &docs); err != nil {
		return docsJSON // return as-is on parse failure
	}

	queryWords := strings.Fields(strings.ToLower(query))
	for i := range docs {
		contentWords := strings.Fields(strings.ToLower(docs[i].Content))
		wordSet := make(map[string]bool, len(contentWords))
		for _, w := range contentWords {
			wordSet[w] = true
		}
		overlap := 0
		for _, w := range queryWords {
			if wordSet[w] {
				overlap++
			}
		}
		if len(queryWords) > 0 {
			docs[i].Score = float64(overlap) / float64(len(queryWords))
		}
	}

	sort.Slice(docs, func(i, j int) bool { return docs[i].Score > docs[j].Score })

	out, _ := json.Marshal(docs)
	return string(out)
}
