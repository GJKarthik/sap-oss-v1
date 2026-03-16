// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package predicates

import (
	"encoding/json"
	"fmt"
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
	mcpResult, err := callMCPTool(p.MCPAddress, p.AuthToken, "extract_entities", map[string]any{
		"query": query,
	})
	if err == nil {
		entityType := stringField(mcpResult, "entity_type", "entityType", "type")
		entityID := stringField(mcpResult, "entity_id", "entityId", "id")
		if entityType != "" && entityID != "" {
			return entityType, entityID, nil
		}
	}

	legacyBody, _ := json.Marshal(map[string]string{"query": query})
	legacyResult, legacyErr := legacyMCPHTTPCall(p.MCPAddress, p.AuthToken, "/mcp/tools/extract_entities", legacyBody)
	if legacyErr != nil {
		if err != nil {
			return "", "", err
		}
		return "", "", legacyErr
	}
	entityType := stringField(legacyResult, "entity_type", "entityType", "type")
	entityID := stringField(legacyResult, "entity_id", "entityId", "id")
	if entityType == "" || entityID == "" {
		return "", "", fmt.Errorf("mcp extract_entities response missing entity fields")
	}
	return entityType, entityID, nil
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
