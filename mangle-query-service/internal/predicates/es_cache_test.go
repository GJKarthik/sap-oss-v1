package predicates

import (
	"testing"

	"github.com/google/mangle/ast"
)

func TestESCachePredicate_ShouldPushdown(t *testing.T) {
	p := &ESCachePredicate{}
	if p.ShouldPushdown() != false {
		t.Error("expected ShouldPushdown to return false")
	}
}

func TestESCachePredicate_ShouldQuery(t *testing.T) {
	p := &ESCachePredicate{}
	inputs := []ast.Constant{ast.String("test query")}
	if !p.ShouldQuery(inputs, nil, nil) {
		t.Error("expected ShouldQuery to return true for non-empty query")
	}
}

func TestESCachePredicate_ShouldQueryEmpty(t *testing.T) {
	p := &ESCachePredicate{}
	if p.ShouldQuery(nil, nil, nil) {
		t.Error("expected ShouldQuery to return false for nil inputs")
	}
}
