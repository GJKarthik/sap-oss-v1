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

// CacheManager handles storing and invalidating cached Q&A pairs in ES.
type CacheManager struct {
	ES    *elasticsearch.Client
	Index string // default: "cache-qa"
}

// NewCacheManager creates a cache manager.
func NewCacheManager(es *elasticsearch.Client) *CacheManager {
	return &CacheManager{ES: es, Index: "cache-qa"}
}

// StoreAnswer caches a resolved Q&A pair in ES.
func (c *CacheManager) StoreAnswer(ctx context.Context, query, answer, sourcePath string) error {
	doc := map[string]interface{}{
		"query_text":   query,
		"answer_text":  answer,
		"source_path":  sourcePath,
		"generated_by": "mangle_query_service",
		"created_at":   time.Now().UTC().Format(time.RFC3339),
		"hit_count":    0,
		"ttl_expires":  time.Now().Add(24 * time.Hour).UTC().Format(time.RFC3339),
	}

	body, _ := json.Marshal(doc)
	res, err := c.ES.Index(c.Index, bytes.NewReader(body), c.ES.Index.WithContext(ctx))
	if err != nil {
		return fmt.Errorf("cache store failed: %w", err)
	}
	defer res.Body.Close()

	if res.IsError() {
		return fmt.Errorf("cache store error: %s", res.String())
	}

	log.Printf("Cache: stored answer for query %q via path %s", query, sourcePath)
	return nil
}

// InvalidateByEntity removes cached answers that reference a specific entity.
func (c *CacheManager) InvalidateByEntity(ctx context.Context, entityRefs []string) (int, error) {
	if len(entityRefs) == 0 {
		return 0, nil
	}

	// Delete by query: find cached answers whose source_path matches any entity ref
	shouldClauses := make([]map[string]interface{}, len(entityRefs))
	for i, ref := range entityRefs {
		shouldClauses[i] = map[string]interface{}{
			"match": map[string]interface{}{
				"source_path": ref,
			},
		}
	}

	query := map[string]interface{}{
		"query": map[string]interface{}{
			"bool": map[string]interface{}{
				"should": shouldClauses,
			},
		},
	}

	body, _ := json.Marshal(query)
	res, err := c.ES.DeleteByQuery(
		[]string{c.Index},
		bytes.NewReader(body),
		c.ES.DeleteByQuery.WithContext(ctx),
	)
	if err != nil {
		return 0, fmt.Errorf("cache invalidation failed: %w", err)
	}
	defer res.Body.Close()

	var result struct {
		Deleted int `json:"deleted"`
	}
	json.NewDecoder(res.Body).Decode(&result)

	if result.Deleted > 0 {
		log.Printf("Cache: invalidated %d entries for entities %v", result.Deleted, entityRefs)
	}
	return result.Deleted, nil
}

// InvalidateExpired removes cached answers past their TTL.
func (c *CacheManager) InvalidateExpired(ctx context.Context) (int, error) {
	query := map[string]interface{}{
		"query": map[string]interface{}{
			"range": map[string]interface{}{
				"ttl_expires": map[string]interface{}{
					"lt": "now",
				},
			},
		},
	}

	body, _ := json.Marshal(query)
	res, err := c.ES.DeleteByQuery(
		[]string{c.Index},
		bytes.NewReader(body),
		c.ES.DeleteByQuery.WithContext(ctx),
	)
	if err != nil {
		return 0, fmt.Errorf("TTL cleanup failed: %w", err)
	}
	defer res.Body.Close()

	var result struct {
		Deleted int `json:"deleted"`
	}
	json.NewDecoder(res.Body).Decode(&result)

	if result.Deleted > 0 {
		log.Printf("Cache: expired %d TTL entries", result.Deleted)
	}
	return result.Deleted, nil
}
