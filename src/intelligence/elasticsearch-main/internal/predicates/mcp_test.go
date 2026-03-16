// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package predicates

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
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

func TestMCPClassify_JSONRPC(t *testing.T) {
	serverCalled := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		serverCalled = true
		if r.URL.Path != "/mcp" {
			t.Fatalf("expected /mcp path, got %s", r.URL.Path)
		}
		var req map[string]any
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("failed decoding request: %v", err)
		}
		params, _ := req["params"].(map[string]any)
		if params["name"] != "classify_query" {
			t.Fatalf("expected classify_query tool, got %v", params["name"])
		}

		resp := map[string]any{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]any{
				"content": []map[string]any{
					{"type": "text", "text": `{"category":"FACTUAL","confidence":0.91}`},
				},
			},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	p := &MCPClassifyPredicate{MCPAddress: srv.URL}
	inputs := []ast.Constant{ast.String("show me order PO-123")}

	var results [][]ast.BaseTerm
	err := p.ExecuteQuery(inputs, nil, nil, func(r []ast.BaseTerm) {
		results = append(results, r)
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !serverCalled {
		t.Fatal("expected remote MCP server to be called")
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
