package predicates

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"

	"github.com/google/mangle/ast"
)

// MCPEntitiesPredicate implements extract_entities/3: (Query, EntityType, EntityId).
type MCPEntitiesPredicate struct {
	MCPAddress string
	AuthToken  string
}

func (p *MCPEntitiesPredicate) ShouldPushdown() bool { return false }

func (p *MCPEntitiesPredicate) ShouldQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term) bool {
	return len(inputs) > 0
}

func (p *MCPEntitiesPredicate) ExecuteQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term, cb func([]ast.BaseTerm)) error {
	if len(inputs) == 0 {
		return fmt.Errorf("extract_entities requires 1 input (query)")
	}

	query, err := inputs[0].StringValue()
	if err != nil {
		return fmt.Errorf("extract_entities: invalid query: %w", err)
	}

	entityType, entityID := p.extract(query)
	if entityType == "" {
		return nil // no entities found
	}

	cb([]ast.BaseTerm{
		ast.String(entityType),
		ast.String(entityID),
	})
	return nil
}

func (p *MCPEntitiesPredicate) extract(query string) (string, string) {
	if p.MCPAddress != "" {
		et, eid, err := p.callMCP(query)
		if err == nil && et != "" {
			return et, eid
		}
	}
	return heuristicExtract(query)
}

func (p *MCPEntitiesPredicate) callMCP(query string) (string, string, error) {
	body, _ := json.Marshal(map[string]string{"query": query})
	req, err := http.NewRequest("POST", p.MCPAddress+"/mcp/tools/extract_entities", bytes.NewReader(body))
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Content-Type", "application/json")
	if p.AuthToken != "" {
		req.Header.Set("Authorization", "Bearer "+p.AuthToken)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()

	data, _ := io.ReadAll(resp.Body)
	var result struct {
		EntityType string `json:"entity_type"`
		EntityID   string `json:"entity_id"`
	}
	if err := json.Unmarshal(data, &result); err != nil {
		return "", "", err
	}
	return result.EntityType, result.EntityID, nil
}

var entityPatterns = map[string]*regexp.Regexp{
	"orders":    regexp.MustCompile(`(?i)(?:order|po)[\s\-#]*([A-Z0-9\-]+)`),
	"customers": regexp.MustCompile(`(?i)customer[\s\-#]*([A-Z0-9\-]+)`),
	"products":  regexp.MustCompile(`(?i)product[\s\-#]*([A-Z0-9\-]+)`),
	"materials": regexp.MustCompile(`(?i)material[\s\-#]*([A-Z0-9\-]+)`),
}

func heuristicExtract(query string) (string, string) {
	q := strings.TrimSpace(query)
	for entityType, pattern := range entityPatterns {
		if match := pattern.FindStringSubmatch(q); len(match) > 1 {
			return entityType, match[1]
		}
	}
	return "", ""
}
