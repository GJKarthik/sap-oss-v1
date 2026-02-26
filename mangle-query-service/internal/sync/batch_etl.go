// Package sync implements HANA → Elasticsearch synchronization pipelines.
package sync

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/elastic/go-elasticsearch/v8"
)

// BatchETL performs scheduled bulk synchronization from HANA to ES.
type BatchETL struct {
	ES       *elasticsearch.Client
	Interval time.Duration // default: 5 minutes
	stopCh   chan struct{}
}

// EntityChange represents a changed record from HANA.
type EntityChange struct {
	EntityType string                 `json:"entity_type"`
	EntityID   string                 `json:"entity_id"`
	Operation  string                 `json:"operation"` // "insert", "update", "delete"
	Fields     map[string]interface{} `json:"fields"`
	ChangedAt  time.Time              `json:"changed_at"`
}

// NewBatchETL creates a batch ETL pipeline.
func NewBatchETL(es *elasticsearch.Client, interval time.Duration) *BatchETL {
	if interval == 0 {
		interval = 5 * time.Minute
	}
	return &BatchETL{
		ES:       es,
		Interval: interval,
		stopCh:   make(chan struct{}),
	}
}

// Start begins the periodic sync loop in a goroutine.
func (b *BatchETL) Start() {
	go b.run()
}

// Stop terminates the sync loop.
func (b *BatchETL) Stop() {
	close(b.stopCh)
}

func (b *BatchETL) run() {
	ticker := time.NewTicker(b.Interval)
	defer ticker.Stop()

	log.Printf("Batch ETL started (interval: %s)", b.Interval)
	for {
		select {
		case <-ticker.C:
			if err := b.SyncOnce(context.Background()); err != nil {
				log.Printf("Batch ETL sync error: %v", err)
			}
		case <-b.stopCh:
			log.Println("Batch ETL stopped")
			return
		}
	}
}

// SyncOnce runs a single sync cycle. In production, this queries HANA for
// changes since last sync. For now it's a no-op placeholder.
func (b *BatchETL) SyncOnce(ctx context.Context) error {
	// TODO: Query HANA for changes since last_synced_at
	// For each change: index into appropriate ES index
	return nil
}

// BulkIndex indexes a batch of entity changes into Elasticsearch.
func (b *BatchETL) BulkIndex(ctx context.Context, changes []EntityChange) error {
	if len(changes) == 0 {
		return nil
	}

	var buf bytes.Buffer
	for _, change := range changes {
		index := fmt.Sprintf("business-%s", change.EntityType)

		if change.Operation == "delete" {
			meta := map[string]interface{}{
				"delete": map[string]interface{}{
					"_index": index,
					"_id":    change.EntityID,
				},
			}
			line, _ := json.Marshal(meta)
			buf.Write(line)
			buf.WriteByte('\n')
			continue
		}

		meta := map[string]interface{}{
			"index": map[string]interface{}{
				"_index": index,
				"_id":    change.EntityID,
			},
		}
		line, _ := json.Marshal(meta)
		buf.Write(line)
		buf.WriteByte('\n')

		doc := map[string]interface{}{
			"hana_key":       change.EntityID,
			"entity_type":    change.EntityType,
			"fields":         change.Fields,
			"display_text":   formatDisplayText(change.Fields),
			"last_synced_at": time.Now().UTC().Format(time.RFC3339),
			"hana_changed_at": change.ChangedAt.UTC().Format(time.RFC3339),
		}
		docLine, _ := json.Marshal(doc)
		buf.Write(docLine)
		buf.WriteByte('\n')
	}

	res, err := b.ES.Bulk(bytes.NewReader(buf.Bytes()), b.ES.Bulk.WithContext(ctx))
	if err != nil {
		return fmt.Errorf("bulk index failed: %w", err)
	}
	defer res.Body.Close()

	if res.IsError() {
		return fmt.Errorf("bulk index error: %s", res.String())
	}

	log.Printf("Batch ETL: indexed %d changes", len(changes))
	return nil
}

func formatDisplayText(fields map[string]interface{}) string {
	var parts []string
	for k, v := range fields {
		parts = append(parts, fmt.Sprintf("%s: %v", k, v))
	}
	result := ""
	for i, p := range parts {
		if i > 0 {
			result += ", "
		}
		result += p
	}
	return result
}
