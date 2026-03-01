// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package resilience

import (
	"testing"
	"time"
)

func TestCircuitBreakerStartsClosed(t *testing.T) {
	cb := NewCircuitBreaker("test", 3, time.Second)
	if cb.GetState() != StateClosed {
		t.Errorf("expected closed, got %s", cb.GetState())
	}
	if !cb.Allow() {
		t.Error("expected closed breaker to allow requests")
	}
}

func TestCircuitBreakerOpensAfterThreshold(t *testing.T) {
	cb := NewCircuitBreaker("test", 3, time.Second)
	cb.RecordFailure()
	cb.RecordFailure()
	cb.RecordFailure()

	if cb.GetState() != StateOpen {
		t.Errorf("expected open after 3 failures, got %s", cb.GetState())
	}
	if cb.Allow() {
		t.Error("expected open breaker to reject requests")
	}
}

func TestCircuitBreakerRecovery(t *testing.T) {
	cb := NewCircuitBreaker("test", 2, 10*time.Millisecond)
	cb.RecordFailure()
	cb.RecordFailure()

	if cb.GetState() != StateOpen {
		t.Fatalf("expected open, got %s", cb.GetState())
	}

	// Wait for recovery timeout
	time.Sleep(15 * time.Millisecond)

	if !cb.Allow() {
		t.Error("expected half-open breaker to allow a test request")
	}
	if cb.GetState() != StateHalfOpen {
		t.Errorf("expected half_open, got %s", cb.GetState())
	}

	cb.RecordSuccess()
	cb.RecordSuccess()

	if cb.GetState() != StateClosed {
		t.Errorf("expected closed after recovery, got %s", cb.GetState())
	}
}

func TestCircuitBreakerResetsOnSuccess(t *testing.T) {
	cb := NewCircuitBreaker("test", 3, time.Second)
	cb.RecordFailure()
	cb.RecordFailure()
	cb.RecordSuccess() // resets failure count

	if cb.GetState() != StateClosed {
		t.Errorf("expected closed after success reset, got %s", cb.GetState())
	}
}

func TestBreakerRegistry(t *testing.T) {
	reg := NewBreakerRegistry()
	cb1 := reg.Get("es")
	cb2 := reg.Get("es")
	if cb1 != cb2 {
		t.Error("expected same breaker instance for same name")
	}

	cb3 := reg.Get("mcp")
	if cb1 == cb3 {
		t.Error("expected different breaker for different name")
	}

	all := reg.All()
	if len(all) != 2 {
		t.Errorf("expected 2 breakers, got %d", len(all))
	}
}
