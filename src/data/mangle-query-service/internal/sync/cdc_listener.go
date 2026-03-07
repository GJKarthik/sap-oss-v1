// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package sync

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/elastic/go-elasticsearch/v8"
)

// CDCListener processes real-time entity changes via the SyncEntity RPC.
type CDCListener struct {
	ES *elasticsearch.Client
}

// NewCDCListener creates a CDC listener.
func NewCDCListener(es *elasticsearch.Client) *CDCListener {
	return &CDCListener{ES: es}
}

// HandleChange processes a single entity change event, indexing into ES
// and returning cache keys that should be invalidated.
func (c *CDCListener) HandleChange(ctx context.Context, entityType, entityID, operation, payloadJSON string) ([]string, error) {
	if c.ES == nil {
		return nil, fmt.Errorf("cdc listener is not configured")
	}

	index := fmt.Sprintf("business-%s", entityType)
	normalizedOp := strings.ToLower(strings.TrimSpace(operation))

	switch normalizedOp {
	case "delete":
		return c.deleteDoc(ctx, index, entityID)
	case "insert", "update":
		return c.upsertDoc(ctx, entityType, index, entityID, payloadJSON)
	default:
		return nil, fmt.Errorf("unknown operation: %s", operation)
	}
}

func (c *CDCListener) deleteDoc(ctx context.Context, index, id string) ([]string, error) {
	res, err := c.ES.Delete(index, id, c.ES.Delete.WithContext(ctx))
	if err != nil {
		return nil, fmt.Errorf("delete failed: %w", err)
	}
	defer res.Body.Close()
	if res.IsError() && res.StatusCode != http.StatusNotFound {
		return nil, fmt.Errorf("delete failed: %s", res.String())
	}

	log.Printf("CDC: deleted %s/%s", index, id)
	// Return entity reference for cache invalidation
	return []string{fmt.Sprintf("%s:%s", index, id)}, nil
}

func (c *CDCListener) upsertDoc(ctx context.Context, entityType, index, id, payloadJSON string) ([]string, error) {
	var fields map[string]interface{}
	if err := json.Unmarshal([]byte(payloadJSON), &fields); err != nil {
		return nil, fmt.Errorf("invalid payload JSON: %w", err)
	}

	doc := map[string]interface{}{
		"hana_key":       id,
		"entity_type":    entityType,
		"fields":         fields,
		"display_text":   formatDisplayText(fields),
		"last_synced_at": time.Now().UTC().Format(time.RFC3339),
	}

	body, err := json.Marshal(doc)
	if err != nil {
		return nil, fmt.Errorf("index failed: encode document: %w", err)
	}
	res, err := c.ES.Index(index, bytes.NewReader(body),
		c.ES.Index.WithDocumentID(id),
		c.ES.Index.WithContext(ctx),
	)
	if err != nil {
		return nil, fmt.Errorf("index failed: %w", err)
	}
	defer res.Body.Close()

	if res.IsError() {
		return nil, fmt.Errorf("index error: %s", res.String())
	}

	log.Printf("CDC: upserted %s/%s", index, id)
	return []string{fmt.Sprintf("%s:%s", index, id)}, nil
}
