package resilience

import (
	"sync"
	"sync/atomic"
)

// Metrics tracks request counts and latencies by resolution path.
type Metrics struct {
	mu          sync.RWMutex
	pathCounts  map[string]*atomic.Int64
	totalCount  atomic.Int64
	errorCount  atomic.Int64
	totalLatMs  atomic.Int64
}

// NewMetrics creates a new metrics tracker.
func NewMetrics() *Metrics {
	return &Metrics{
		pathCounts: make(map[string]*atomic.Int64),
	}
}

// RecordResolve records a successful resolution.
func (m *Metrics) RecordResolve(path string, latencyMs int64) {
	m.totalCount.Add(1)
	m.totalLatMs.Add(latencyMs)

	m.mu.RLock()
	counter, ok := m.pathCounts[path]
	m.mu.RUnlock()

	if !ok {
		m.mu.Lock()
		if counter, ok = m.pathCounts[path]; !ok {
			counter = &atomic.Int64{}
			m.pathCounts[path] = counter
		}
		m.mu.Unlock()
	}
	counter.Add(1)
}

// RecordError records a resolution error.
func (m *Metrics) RecordError() {
	m.totalCount.Add(1)
	m.errorCount.Add(1)
}

// Snapshot returns current metrics as a map.
func (m *Metrics) Snapshot() map[string]float32 {
	result := map[string]float32{
		"total_requests": float32(m.totalCount.Load()),
		"total_errors":   float32(m.errorCount.Load()),
	}

	total := m.totalCount.Load()
	if total > 0 {
		result["avg_latency_ms"] = float32(m.totalLatMs.Load()) / float32(total)
		result["error_rate"] = float32(m.errorCount.Load()) / float32(total)
	}

	m.mu.RLock()
	defer m.mu.RUnlock()
	for path, counter := range m.pathCounts {
		result["path_"+path] = float32(counter.Load())
		if total > 0 {
			result["pct_"+path] = float32(counter.Load()) / float32(total) * 100
		}
	}
	return result
}
