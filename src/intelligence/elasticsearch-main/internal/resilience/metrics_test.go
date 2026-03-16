// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package resilience

import "testing"

func TestMetricsRecordResolve(t *testing.T) {
	m := NewMetrics()
	m.RecordResolve("cache", 5)
	m.RecordResolve("cache", 3)
	m.RecordResolve("llm", 200)

	snap := m.Snapshot()
	if snap["total_requests"] != 3 {
		t.Errorf("expected 3 total, got %.0f", snap["total_requests"])
	}
	if snap["path_cache"] != 2 {
		t.Errorf("expected 2 cache hits, got %.0f", snap["path_cache"])
	}
	if snap["path_llm"] != 1 {
		t.Errorf("expected 1 llm, got %.0f", snap["path_llm"])
	}
}

func TestMetricsRecordError(t *testing.T) {
	m := NewMetrics()
	m.RecordResolve("cache", 5)
	m.RecordError()

	snap := m.Snapshot()
	if snap["total_errors"] != 1 {
		t.Errorf("expected 1 error, got %.0f", snap["total_errors"])
	}
	if snap["error_rate"] != 0.5 {
		t.Errorf("expected 0.5 error rate, got %f", snap["error_rate"])
	}
}

func TestMetricsPercentages(t *testing.T) {
	m := NewMetrics()
	for i := 0; i < 80; i++ {
		m.RecordResolve("cache", 5)
	}
	for i := 0; i < 20; i++ {
		m.RecordResolve("llm", 200)
	}

	snap := m.Snapshot()
	if snap["pct_cache"] != 80 {
		t.Errorf("expected 80%% cache, got %.0f%%", snap["pct_cache"])
	}
	if snap["pct_llm"] != 20 {
		t.Errorf("expected 20%% llm, got %.0f%%", snap["pct_llm"])
	}
}
