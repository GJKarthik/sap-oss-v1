// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
// Package predicates provides built-in Mangle external predicates for
// governance, GDPR, and environment-context rules used in governance.mg.
package predicates

import (
	"log/slog"
	"os"
	"sync"
	"time"

	"github.com/google/mangle/ast"
)

// ============================================================================
// CurrentUserRolePredicate — current_user_role(Role)
//
// Produces a single binding for Role from the per-request context set by the
// gRPC handler via SetRole(). Returns "anonymous" when no role has been set.
// ============================================================================

type CurrentUserRolePredicate struct {
	mu   sync.RWMutex
	role string
}

// SetRole stores the authenticated user role before each Mangle evaluation.
// Call this from the gRPC handler (under its own lock) before Resolve().
func (p *CurrentUserRolePredicate) SetRole(role string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if role == "" {
		p.role = "anonymous"
	} else {
		p.role = role
	}
}

func (p *CurrentUserRolePredicate) ShouldPushdown() bool { return false }

func (p *CurrentUserRolePredicate) ShouldQuery(inputs []ast.Constant, _ []ast.BaseTerm, _ []ast.Term) bool {
	return len(inputs) == 0 // no input required; we produce the binding
}

func (p *CurrentUserRolePredicate) ExecuteQuery(_ []ast.Constant, _ []ast.BaseTerm, _ []ast.Term, cb func([]ast.BaseTerm)) error {
	p.mu.RLock()
	role := p.role
	if role == "" {
		role = "anonymous"
	}
	p.mu.RUnlock()
	cb([]ast.BaseTerm{ast.String(role)})
	return nil
}

// ============================================================================
// CurrentDatePredicate — current_date(DateString)
//
// Produces today's date as an ISO-8601 string (YYYY-MM-DD).
// Used in data_retention_expired/2 and time-bounded policy rules.
// ============================================================================

type CurrentDatePredicate struct{}

func (p *CurrentDatePredicate) ShouldPushdown() bool { return false }
func (p *CurrentDatePredicate) ShouldQuery(_ []ast.Constant, _ []ast.BaseTerm, _ []ast.Term) bool {
	return true
}
func (p *CurrentDatePredicate) ExecuteQuery(_ []ast.Constant, _ []ast.BaseTerm, _ []ast.Term, cb func([]ast.BaseTerm)) error {
	cb([]ast.BaseTerm{ast.String(time.Now().UTC().Format("2006-01-02"))})
	return nil
}

// ============================================================================
// EnvironmentPredicate — environment(Env)
//
// Matches when the supplied string equals MQS_ENVIRONMENT (default: "production").
// Rules like must_anonymize use environment("non-production") to gate behaviour.
// ============================================================================

type EnvironmentPredicate struct{}

func (p *EnvironmentPredicate) ShouldPushdown() bool { return false }
func (p *EnvironmentPredicate) ShouldQuery(inputs []ast.Constant, _ []ast.BaseTerm, _ []ast.Term) bool {
	return len(inputs) >= 1
}
func (p *EnvironmentPredicate) ExecuteQuery(inputs []ast.Constant, _ []ast.BaseTerm, _ []ast.Term, cb func([]ast.BaseTerm)) error {
	current := os.Getenv("MQS_ENVIRONMENT")
	if current == "" {
		current = "production"
	}
	if len(inputs) == 0 {
		cb([]ast.BaseTerm{ast.String(current)})
		return nil
	}
	want, err := inputs[0].StringValue()
	if err != nil || want != current {
		return nil // no match → rule body fails
	}
	cb([]ast.BaseTerm{}) // matched; no new bindings
	return nil
}

// ============================================================================
// ConsentVerifiedPredicate — consent_verified(EntityType, EntityID)
//
// Verifies that a data subject has granted consent for AI processing.
// Production implementation should query the consent management service.
// Default: denies all (safe default for regulated environments).
// ============================================================================

type ConsentVerifiedPredicate struct {
	// ConsentServiceURL is the HTTP endpoint of the consent management service.
	// If empty, all consent checks are denied (safe default).
	ConsentServiceURL string
}

func (p *ConsentVerifiedPredicate) ShouldPushdown() bool { return false }
func (p *ConsentVerifiedPredicate) ShouldQuery(inputs []ast.Constant, _ []ast.BaseTerm, _ []ast.Term) bool {
	return len(inputs) >= 2
}
func (p *ConsentVerifiedPredicate) ExecuteQuery(inputs []ast.Constant, _ []ast.BaseTerm, _ []ast.Term, cb func([]ast.BaseTerm)) error {
	if len(inputs) < 2 || p.ConsentServiceURL == "" {
		// Safe default: no consent granted when service is unconfigured
		return nil
	}
	entityType, _ := inputs[0].StringValue()
	entityID, _   := inputs[1].StringValue()
	// TODO: call p.ConsentServiceURL/v1/check?entityType=X&entityId=Y
	slog.Debug("consent_verified called (not yet wired to consent service)",
		"entity_type", entityType, "entity_id", entityID)
	return nil
}

// ============================================================================
// LogAuditPredicate — log_audit(Query, Reason)
//
// Side-effecting predicate: writes a structured audit log entry and always
// succeeds (returns one empty binding). Never blocks rule evaluation.
// ============================================================================

type LogAuditPredicate struct {
	Logger *slog.Logger
}

func (p *LogAuditPredicate) ShouldPushdown() bool { return false }
func (p *LogAuditPredicate) ShouldQuery(inputs []ast.Constant, _ []ast.BaseTerm, _ []ast.Term) bool {
	return len(inputs) >= 2
}
func (p *LogAuditPredicate) ExecuteQuery(inputs []ast.Constant, _ []ast.BaseTerm, _ []ast.Term, cb func([]ast.BaseTerm)) error {
	logger := p.Logger
	if logger == nil {
		logger = slog.Default()
	}
	if len(inputs) >= 2 {
		query, _  := inputs[0].StringValue()
		reason, _ := inputs[1].StringValue()
		logger.Info("mangle audit event",
			"query",  query,
			"reason", reason,
			"ts",     time.Now().UTC().Format(time.RFC3339),
		)
	}
	cb([]ast.BaseTerm{}) // always succeeds
	return nil
}

