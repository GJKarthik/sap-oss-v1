package predicates

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
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
	body, _ := json.Marshal(map[string]string{"query": query})
	req, err := http.NewRequest("POST", p.MCPAddress+"/mcp/tools/classify_query", bytes.NewReader(body))
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if p.AuthToken != "" {
		req.Header.Set("Authorization", "Bearer "+p.AuthToken)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", 0, err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(resp.Body)
	var result struct {
		Category   string  `json:"category"`
		Confidence float64 `json:"confidence"`
	}
	if err := json.Unmarshal(data, &result); err != nil {
		return "", 0, err
	}
	return result.Category, result.Confidence, nil
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
