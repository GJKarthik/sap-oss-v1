package engine

import "testing"

func TestNewMangleEngine(t *testing.T) {
	eng, err := New("../../rules/")
	if err != nil {
		t.Fatalf("failed to create engine: %v", err)
	}
	if eng == nil {
		t.Fatal("engine is nil")
	}
}

func TestResolveWithMockFacts(t *testing.T) {
	eng, err := New("../../rules/")
	if err != nil {
		t.Fatalf("failed to create engine: %v", err)
	}

	err = eng.DefineFact(`es_cache_lookup("what is our return policy", "Our return policy allows 30-day returns.", 97).`)
	if err != nil {
		t.Fatalf("failed to define fact: %v", err)
	}

	result, err := eng.Resolve("what is our return policy")
	if err != nil {
		t.Fatalf("resolve failed: %v", err)
	}
	if result.Path != "cache" {
		t.Errorf("expected path 'cache', got '%s'", result.Path)
	}
	if result.Answer == "" {
		t.Error("expected non-empty answer")
	}
}
