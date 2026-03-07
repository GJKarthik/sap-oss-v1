// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package engine

import "testing"

func newTestEngine(t *testing.T) *MangleEngine {
	t.Helper()
	eng, err := New("../../rules/")
	if err != nil {
		t.Fatalf("failed to create engine: %v", err)
	}
	return eng
}

func assertEqual(t *testing.T, got, want string) {
	t.Helper()
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestClassifyCached(t *testing.T) {
	eng := newTestEngine(t)
	eng.DefineFact(`es_cache_lookup("return policy", "30-day returns", 97).`)

	result, err := eng.Resolve("return policy")
	if err != nil {
		t.Fatalf("resolve failed: %v", err)
	}
	assertEqual(t, result.Path, "cache")
}

func TestClassifyFactual(t *testing.T) {
	eng := newTestEngine(t)
	eng.DefineFact(`classify_query("show me order PO-123", "FACTUAL", 92).`)
	eng.DefineFact(`extract_entities("show me order PO-123", "orders", "PO-123").`)
	eng.DefineFact(`es_search("orders", "PO-123", "Order PO-123: delivered", 99).`)

	result, err := eng.Resolve("show me order PO-123")
	if err != nil {
		t.Fatalf("resolve failed: %v", err)
	}
	assertEqual(t, result.Path, "factual")
}

func TestClassifyRAG(t *testing.T) {
	eng := newTestEngine(t)
	eng.DefineFact(`classify_query("how to configure SSO", "RAG_RETRIEVAL", 85).`)
	eng.DefineFact(`es_hybrid_search("how to configure SSO", "SSO setup guide content", 82).`)
	eng.DefineFact(`rerank("how to configure SSO", "SSO setup guide content", "SSO setup guide reranked").`)

	result, err := eng.Resolve("how to configure SSO")
	if err != nil {
		t.Fatalf("resolve failed: %v", err)
	}
	assertEqual(t, result.Path, "rag")
}

func TestClassifyLLMRequired(t *testing.T) {
	eng := newTestEngine(t)
	eng.DefineFact(`classify_query("why did sales drop in Q3", "LLM_REQUIRED", 88).`)
	eng.DefineFact(`es_hybrid_search("why did sales drop in Q3", "Q3 report data", 70).`)
	eng.DefineFact(`llm_generate("why did sales drop in Q3", "Q3 report data", "Sales dropped because of market conditions.").`)

	result, err := eng.Resolve("why did sales drop in Q3")
	if err != nil {
		t.Fatalf("resolve failed: %v", err)
	}
	assertEqual(t, result.Path, "llm")
}

func TestFallbackToLLM(t *testing.T) {
	eng := newTestEngine(t)
	// No classification — should fall through to llm_fallback
	eng.DefineFact(`es_hybrid_search("something weird", "some context", 30).`)
	eng.DefineFact(`llm_generate("something weird", "some context", "I can help with that.").`)

	result, err := eng.Resolve("something weird")
	if err != nil {
		t.Fatalf("resolve failed: %v", err)
	}
	assertEqual(t, result.Path, "llm_fallback")
}
