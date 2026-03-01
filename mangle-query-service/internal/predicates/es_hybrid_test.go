// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package predicates

import (
	"testing"

	"github.com/google/mangle/ast"
)

func TestESHybridPredicate_ShouldQuery(t *testing.T) {
	p := &ESHybridPredicate{}
	inputs := []ast.Constant{ast.String("how to configure SSO")}
	if !p.ShouldQuery(inputs, nil, nil) {
		t.Error("expected ShouldQuery to return true")
	}
}

func TestESHybridPredicate_ShouldQueryEmpty(t *testing.T) {
	p := &ESHybridPredicate{}
	if p.ShouldQuery(nil, nil, nil) {
		t.Error("expected ShouldQuery to return false for empty inputs")
	}
}
