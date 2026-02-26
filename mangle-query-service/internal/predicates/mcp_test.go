package predicates

import (
	"testing"

	"github.com/google/mangle/ast"
)

func TestMCPClassify_Heuristic(t *testing.T) {
	p := &MCPClassifyPredicate{} // no MCP address = heuristic mode
	inputs := []ast.Constant{ast.String("show me order PO-123")}

	var results [][]ast.BaseTerm
	err := p.ExecuteQuery(inputs, nil, nil, func(r []ast.BaseTerm) {
		results = append(results, r)
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1 result, got %d", len(results))
	}
	cat, _ := results[0][0].(ast.Constant).StringValue()
	if cat != "FACTUAL" {
		t.Errorf("expected FACTUAL, got %s", cat)
	}
}

func TestMCPEntities_Heuristic(t *testing.T) {
	p := &MCPEntitiesPredicate{}
	inputs := []ast.Constant{ast.String("show me order PO-123")}

	var results [][]ast.BaseTerm
	err := p.ExecuteQuery(inputs, nil, nil, func(r []ast.BaseTerm) {
		results = append(results, r)
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1 result, got %d", len(results))
	}
	entityType, _ := results[0][0].(ast.Constant).StringValue()
	entityID, _ := results[0][1].(ast.Constant).StringValue()
	if entityType != "orders" {
		t.Errorf("expected entity type 'orders', got %s", entityType)
	}
	if entityID != "PO-123" {
		t.Errorf("expected entity ID 'PO-123', got %s", entityID)
	}
}

func TestMCPRerank_Heuristic(t *testing.T) {
	p := &MCPRerankPredicate{}
	docsJSON := `[{"content":"SSO setup guide for BTP"},{"content":"unrelated stuff"}]`
	inputs := []ast.Constant{ast.String("SSO setup"), ast.String(docsJSON)}

	var results [][]ast.BaseTerm
	err := p.ExecuteQuery(inputs, nil, nil, func(r []ast.BaseTerm) {
		results = append(results, r)
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1 result, got %d", len(results))
	}
	reranked, _ := results[0][0].(ast.Constant).StringValue()
	if reranked == "" {
		t.Error("expected non-empty reranked output")
	}
}

func TestMCPLLM_Fallback(t *testing.T) {
	p := &MCPLLMPredicate{}
	inputs := []ast.Constant{ast.String("why did sales drop"), ast.String("Q3 data")}

	var results [][]ast.BaseTerm
	err := p.ExecuteQuery(inputs, nil, nil, func(r []ast.BaseTerm) {
		results = append(results, r)
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1 result, got %d", len(results))
	}
	answer, _ := results[0][0].(ast.Constant).StringValue()
	if answer == "" {
		t.Error("expected non-empty answer")
	}
}
