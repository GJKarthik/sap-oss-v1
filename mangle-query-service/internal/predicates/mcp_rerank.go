package predicates

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
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
	body, _ := json.Marshal(map[string]string{"query": query, "documents": docsJSON})
	req, err := http.NewRequest("POST", p.MCPAddress+"/mcp/tools/rerank", bytes.NewReader(body))
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
		Documents string `json:"documents"`
	}
	if err := json.Unmarshal(data, &result); err != nil {
		return "", err
	}
	return result.Documents, nil
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
