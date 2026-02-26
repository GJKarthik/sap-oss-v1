// Package resilience provides circuit breaker and retry patterns.
package resilience

import (
	"fmt"
	"sync"
	"time"
)

// State represents the circuit breaker state.
type State int

const (
	StateClosed   State = iota // normal operation
	StateOpen                  // failing, reject requests
	StateHalfOpen              // testing if service recovered
)

func (s State) String() string {
	switch s {
	case StateClosed:
		return "closed"
	case StateOpen:
		return "open"
	case StateHalfOpen:
		return "half_open"
	}
	return "unknown"
}

// CircuitBreaker implements the circuit breaker pattern.
type CircuitBreaker struct {
	mu               sync.Mutex
	name             string
	state            State
	failureCount     int
	successCount     int
	failureThreshold int
	recoveryTimeout  time.Duration
	lastFailure      time.Time
}

// NewCircuitBreaker creates a circuit breaker with the given thresholds.
func NewCircuitBreaker(name string, failureThreshold int, recoveryTimeout time.Duration) *CircuitBreaker {
	return &CircuitBreaker{
		name:             name,
		state:            StateClosed,
		failureThreshold: failureThreshold,
		recoveryTimeout:  recoveryTimeout,
	}
}

// Allow returns true if the request should proceed.
func (cb *CircuitBreaker) Allow() bool {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	switch cb.state {
	case StateClosed:
		return true
	case StateOpen:
		if time.Since(cb.lastFailure) > cb.recoveryTimeout {
			cb.state = StateHalfOpen
			return true
		}
		return false
	case StateHalfOpen:
		return true
	}
	return false
}

// RecordSuccess records a successful call.
func (cb *CircuitBreaker) RecordSuccess() {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	if cb.state == StateHalfOpen {
		cb.successCount++
		if cb.successCount >= 2 {
			cb.state = StateClosed
			cb.failureCount = 0
			cb.successCount = 0
		}
	} else {
		cb.failureCount = 0
	}
}

// RecordFailure records a failed call.
func (cb *CircuitBreaker) RecordFailure() {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	cb.failureCount++
	cb.lastFailure = time.Now()

	if cb.failureCount >= cb.failureThreshold {
		cb.state = StateOpen
		cb.successCount = 0
	}
}

// State returns the current circuit breaker state.
func (cb *CircuitBreaker) GetState() State {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	return cb.state
}

// Name returns the circuit breaker name.
func (cb *CircuitBreaker) Name() string {
	return cb.name
}

// String returns a human-readable status.
func (cb *CircuitBreaker) String() string {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	return fmt.Sprintf("cb[%s]: state=%s failures=%d", cb.name, cb.state, cb.failureCount)
}

// BreakerRegistry holds named circuit breakers.
type BreakerRegistry struct {
	mu       sync.RWMutex
	breakers map[string]*CircuitBreaker
}

// NewBreakerRegistry creates a registry.
func NewBreakerRegistry() *BreakerRegistry {
	return &BreakerRegistry{breakers: make(map[string]*CircuitBreaker)}
}

// Get returns the breaker for the given name, creating if needed.
func (r *BreakerRegistry) Get(name string) *CircuitBreaker {
	r.mu.RLock()
	if cb, ok := r.breakers[name]; ok {
		r.mu.RUnlock()
		return cb
	}
	r.mu.RUnlock()

	r.mu.Lock()
	defer r.mu.Unlock()
	if cb, ok := r.breakers[name]; ok {
		return cb
	}
	cb := NewCircuitBreaker(name, 5, 30*time.Second)
	r.breakers[name] = cb
	return cb
}

// All returns all registered breakers.
func (r *BreakerRegistry) All() []*CircuitBreaker {
	r.mu.RLock()
	defer r.mu.RUnlock()
	result := make([]*CircuitBreaker, 0, len(r.breakers))
	for _, cb := range r.breakers {
		result = append(result, cb)
	}
	return result
}
