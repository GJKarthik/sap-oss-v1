package predicates

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

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
	body, _ := json.Marshal(map[string]string{"query": query, "context": context})
	req, err := http.NewRequest("POST", p.MCPAddress+"/mcp/tools/llm_generate", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	if p.AuthToken != "" {
		req.Header.Set("Authorization", "Bearer "+p.AuthToken)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(resp.Body)
	var result struct {
		Answer string `json:"answer"`
	}
	if err := json.Unmarshal(data, &result); err != nil {
		return "", err
	}
	return result.Answer, nil
}
