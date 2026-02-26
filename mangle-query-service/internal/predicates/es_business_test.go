package predicates

import (
	"testing"

	"github.com/google/mangle/ast"
)

func TestESBusinessPredicate_ShouldQuery(t *testing.T) {
	p := &ESBusinessPredicate{}
	inputs := []ast.Constant{ast.String("orders"), ast.String("PO-123")}
	if !p.ShouldQuery(inputs, nil, nil) {
		t.Error("expected ShouldQuery to return true for 2 inputs")
	}
}

func TestESBusinessPredicate_ShouldQueryInsufficient(t *testing.T) {
	p := &ESBusinessPredicate{}
	inputs := []ast.Constant{ast.String("orders")}
	if p.ShouldQuery(inputs, nil, nil) {
		t.Error("expected ShouldQuery to return false for only 1 input")
	}
}
