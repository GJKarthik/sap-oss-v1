package sync

import (
	"testing"
	"time"
)

func TestNewBatchETL(t *testing.T) {
	etl := NewBatchETL(nil, 0)
	if etl == nil {
		t.Fatal("expected non-nil ETL")
	}
	if etl.Interval != 5*time.Minute {
		t.Errorf("expected default interval 5m, got %s", etl.Interval)
	}
}

func TestNewBatchETLCustomInterval(t *testing.T) {
	etl := NewBatchETL(nil, 10*time.Minute)
	if etl.Interval != 10*time.Minute {
		t.Errorf("expected interval 10m, got %s", etl.Interval)
	}
}

func TestFormatDisplayText(t *testing.T) {
	fields := map[string]interface{}{
		"name": "Widget A",
	}
	text := formatDisplayText(fields)
	if text == "" {
		t.Error("expected non-empty display text")
	}
}

func TestBulkIndexEmpty(t *testing.T) {
	etl := NewBatchETL(nil, time.Minute)
	err := etl.BulkIndex(nil, nil)
	if err != nil {
		t.Errorf("expected no error for empty changes, got %v", err)
	}
}
