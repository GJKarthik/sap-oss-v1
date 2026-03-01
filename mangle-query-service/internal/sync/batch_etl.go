// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
// Package sync implements HANA → Elasticsearch synchronization pipelines.
package sync

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/elastic/go-elasticsearch/v8"
	_ "github.com/SAP/go-hdb/driver" // SAP HANA driver
)

// HANAConfig holds HANA connection parameters.
type HANAConfig struct {
	Host     string
	Port     int
	User     string
	Password string
	Schema   string
}

// SyncEntity defines an entity table to sync from HANA.
type SyncEntity struct {
	TableName      string   // HANA table name (e.g., "ACDOCA", "KNA1")
	EntityType     string   // Entity type for ES index (e.g., "journal_entry", "customer")
	KeyColumns     []string // Primary key columns
	ChangedAtField string   // Timestamp field for incremental sync (e.g., "CPUDT")
	SelectFields   []string // Fields to sync (nil = all)
}

// BatchETL performs scheduled bulk synchronization from HANA to ES.
type BatchETL struct {
	ES             *elasticsearch.Client
	DB             *sql.DB // HANA connection
	HANAConfig     *HANAConfig
	Interval       time.Duration // default: 5 minutes
	Entities       []SyncEntity  // Entities to sync
	LastSyncedAt   time.Time     // Last successful sync timestamp
	stopCh         chan struct{}
	startOnce      sync.Once
	stopOnce       sync.Once
	lastSyncedMu   sync.RWMutex
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
	b.startOnce.Do(func() {
		go b.run()
	})
}

// Stop terminates the sync loop.
func (b *BatchETL) Stop() {
	b.stopOnce.Do(func() {
		close(b.stopCh)
	})
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

// ConnectHANA establishes a connection to SAP HANA using the configured parameters.
func (b *BatchETL) ConnectHANA() error {
	if b.HANAConfig == nil {
		return fmt.Errorf("HANA config not provided")
	}

	dsn := fmt.Sprintf("hdb://%s:%s@%s:%d?schema=%s",
		b.HANAConfig.User,
		b.HANAConfig.Password,
		b.HANAConfig.Host,
		b.HANAConfig.Port,
		b.HANAConfig.Schema,
	)

	db, err := sql.Open("hdb", dsn)
	if err != nil {
		return fmt.Errorf("failed to open HANA connection: %w", err)
	}

	// Test connection
	if err := db.PingContext(context.Background()); err != nil {
		db.Close()
		return fmt.Errorf("failed to ping HANA: %w", err)
	}

	b.DB = db
	log.Printf("Connected to HANA at %s:%d", b.HANAConfig.Host, b.HANAConfig.Port)
	return nil
}

// CloseHANA closes the HANA connection.
func (b *BatchETL) CloseHANA() {
	if b.DB != nil {
		b.DB.Close()
		b.DB = nil
	}
}

// SetLastSyncedAt sets the last synced timestamp thread-safely.
func (b *BatchETL) SetLastSyncedAt(t time.Time) {
	b.lastSyncedMu.Lock()
	defer b.lastSyncedMu.Unlock()
	b.LastSyncedAt = t
}

// GetLastSyncedAt gets the last synced timestamp thread-safely.
func (b *BatchETL) GetLastSyncedAt() time.Time {
	b.lastSyncedMu.RLock()
	defer b.lastSyncedMu.RUnlock()
	return b.LastSyncedAt
}

// SyncOnce runs a single sync cycle, querying HANA for changes since last sync
// and indexing them into Elasticsearch.
func (b *BatchETL) SyncOnce(ctx context.Context) error {
	if b.DB == nil {
		// Try to connect if not connected
		if b.HANAConfig != nil {
			if err := b.ConnectHANA(); err != nil {
				return fmt.Errorf("sync failed: %w", err)
			}
		} else {
			return fmt.Errorf("sync failed: no HANA connection configured")
		}
	}

	if len(b.Entities) == 0 {
		log.Println("Batch ETL: no entities configured for sync")
		return nil
	}

	lastSynced := b.GetLastSyncedAt()
	syncStartTime := time.Now()
	totalChanges := 0

	for _, entity := range b.Entities {
		changes, err := b.queryEntityChanges(ctx, entity, lastSynced)
		if err != nil {
			log.Printf("Batch ETL: error querying %s: %v", entity.TableName, err)
			continue
		}

		if len(changes) > 0 {
			if err := b.BulkIndex(ctx, changes); err != nil {
				log.Printf("Batch ETL: error indexing %s: %v", entity.TableName, err)
				continue
			}
			totalChanges += len(changes)
		}
	}

	// Update last synced timestamp on success
	b.SetLastSyncedAt(syncStartTime)
	log.Printf("Batch ETL: sync complete, processed %d changes", totalChanges)
	return nil
}

// queryEntityChanges queries HANA for changes to a specific entity since lastSynced.
func (b *BatchETL) queryEntityChanges(ctx context.Context, entity SyncEntity, lastSynced time.Time) ([]EntityChange, error) {
	// Build SELECT clause
	selectCols := "*"
	if len(entity.SelectFields) > 0 {
		selectCols = strings.Join(entity.SelectFields, ", ")
	}

	// Build WHERE clause for incremental sync
	var whereClause string
	var args []interface{}
	if !lastSynced.IsZero() && entity.ChangedAtField != "" {
		whereClause = fmt.Sprintf("WHERE %s > ?", entity.ChangedAtField)
		args = append(args, lastSynced)
	}

	// Build query
	query := fmt.Sprintf("SELECT %s FROM %s %s ORDER BY %s",
		selectCols,
		entity.TableName,
		whereClause,
		entity.ChangedAtField,
	)

	// If no ChangedAtField, just select all (full sync)
	if entity.ChangedAtField == "" {
		query = fmt.Sprintf("SELECT %s FROM %s", selectCols, entity.TableName)
	}

	log.Printf("Batch ETL: querying %s: %s", entity.TableName, query)

	rows, err := b.DB.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("query failed: %w", err)
	}
	defer rows.Close()

	// Get column names
	columns, err := rows.Columns()
	if err != nil {
		return nil, fmt.Errorf("get columns failed: %w", err)
	}

	var changes []EntityChange
	for rows.Next() {
		// Create slice of interface{} to hold column values
		values := make([]interface{}, len(columns))
		valuePtrs := make([]interface{}, len(columns))
		for i := range values {
			valuePtrs[i] = &values[i]
		}

		if err := rows.Scan(valuePtrs...); err != nil {
			return nil, fmt.Errorf("scan failed: %w", err)
		}

		// Build fields map
		fields := make(map[string]interface{})
		for i, col := range columns {
			fields[col] = values[i]
		}

		// Build entity ID from key columns
		entityID := b.buildEntityID(entity.KeyColumns, fields)

		// Get changed timestamp
		var changedAt time.Time
		if entity.ChangedAtField != "" {
			if ts, ok := fields[entity.ChangedAtField]; ok {
				switch v := ts.(type) {
				case time.Time:
					changedAt = v
				case string:
					changedAt, _ = time.Parse(time.RFC3339, v)
				}
			}
		}
		if changedAt.IsZero() {
			changedAt = time.Now()
		}

		changes = append(changes, EntityChange{
			EntityType: entity.EntityType,
			EntityID:   entityID,
			Operation:  "upsert", // HANA doesn't give us insert vs update easily
			Fields:     fields,
			ChangedAt:  changedAt,
		})
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("row iteration failed: %w", err)
	}

	log.Printf("Batch ETL: found %d changes in %s", len(changes), entity.TableName)
	return changes, nil
}

// buildEntityID creates a composite key from the specified key columns.
func (b *BatchETL) buildEntityID(keyColumns []string, fields map[string]interface{}) string {
	if len(keyColumns) == 0 {
		// Fallback: use first field as key
		for _, v := range fields {
			return fmt.Sprintf("%v", v)
		}
		return ""
	}

	var parts []string
	for _, col := range keyColumns {
		if val, ok := fields[col]; ok {
			parts = append(parts, fmt.Sprintf("%v", val))
		}
	}
	return strings.Join(parts, "-")
}

// AddEntity adds an entity to the sync list.
func (b *BatchETL) AddEntity(entity SyncEntity) {
	b.Entities = append(b.Entities, entity)
}

// DefaultSAPEntities returns common SAP entity definitions for sync.
func DefaultSAPEntities() []SyncEntity {
	return []SyncEntity{
		{
			TableName:      "ACDOCA",
			EntityType:     "journal_entry",
			KeyColumns:     []string{"RCLNT", "RLDNR", "RBUKRS", "GJAHR", "BELNR", "DOCLN"},
			ChangedAtField: "CPUDT",
			SelectFields:   []string{"RCLNT", "RLDNR", "RBUKRS", "GJAHR", "BELNR", "DOCLN", "RACCT", "RHCUR", "HSL", "CPUDT"},
		},
		{
			TableName:      "KNA1",
			EntityType:     "customer",
			KeyColumns:     []string{"MANDT", "KUNNR"},
			ChangedAtField: "UPDAT",
			SelectFields:   []string{"MANDT", "KUNNR", "NAME1", "NAME2", "LAND1", "ORT01", "UPDAT"},
		},
		{
			TableName:      "LFA1",
			EntityType:     "vendor",
			KeyColumns:     []string{"MANDT", "LIFNR"},
			ChangedAtField: "UPDAT",
			SelectFields:   []string{"MANDT", "LIFNR", "NAME1", "NAME2", "LAND1", "ORT01", "UPDAT"},
		},
		{
			TableName:      "MARA",
			EntityType:     "material",
			KeyColumns:     []string{"MANDT", "MATNR"},
			ChangedAtField: "LAEDA",
			SelectFields:   []string{"MANDT", "MATNR", "MTART", "MATKL", "MEINS", "LAEDA"},
		},
		{
			TableName:      "VBAK",
			EntityType:     "sales_order",
			KeyColumns:     []string{"MANDT", "VBELN"},
			ChangedAtField: "AEDAT",
			SelectFields:   []string{"MANDT", "VBELN", "KUNNR", "AUART", "NETWR", "WAERK", "AEDAT"},
		},
		{
			TableName:      "EKKO",
			EntityType:     "purchase_order",
			KeyColumns:     []string{"MANDT", "EBELN"},
			ChangedAtField: "AEDAT",
			SelectFields:   []string{"MANDT", "EBELN", "LIFNR", "BSART", "RLWRT", "WAERS", "AEDAT"},
		},
	}
}

// BulkIndex indexes a batch of entity changes into Elasticsearch.
func (b *BatchETL) BulkIndex(ctx context.Context, changes []EntityChange) error {
	if len(changes) == 0 {
		return nil
	}
	if b.ES == nil {
		return fmt.Errorf("bulk index failed: elasticsearch client is not configured")
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
			line, err := json.Marshal(meta)
			if err != nil {
				return fmt.Errorf("bulk index failed: encode delete metadata: %w", err)
			}
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
		line, err := json.Marshal(meta)
		if err != nil {
			return fmt.Errorf("bulk index failed: encode index metadata: %w", err)
		}
		buf.Write(line)
		buf.WriteByte('\n')

		doc := map[string]interface{}{
			"hana_key":        change.EntityID,
			"entity_type":     change.EntityType,
			"fields":          change.Fields,
			"display_text":    formatDisplayText(change.Fields),
			"last_synced_at":  time.Now().UTC().Format(time.RFC3339),
			"hana_changed_at": change.ChangedAt.UTC().Format(time.RFC3339),
		}
		docLine, err := json.Marshal(doc)
		if err != nil {
			return fmt.Errorf("bulk index failed: encode document: %w", err)
		}
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
	if len(fields) == 0 {
		return ""
	}

	keys := make([]string, 0, len(fields))
	for k := range fields {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var b strings.Builder
	for i, key := range keys {
		if i > 0 {
			b.WriteString(", ")
		}
		b.WriteString(fmt.Sprintf("%s: %v", key, fields[key]))
	}
	return b.String()
}
