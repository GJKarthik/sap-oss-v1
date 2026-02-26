package es

import (
	"context"
	"fmt"
	"strings"
)

// CacheQAMapping defines the ES index mapping for cached question-answer pairs.
const CacheQAMapping = `{
	"mappings": {
		"properties": {
			"query_text":      {"type": "text"},
			"query_embedding": {"type": "dense_vector", "dims": 1536, "similarity": "cosine"},
			"answer_text":     {"type": "text"},
			"source_path":     {"type": "keyword"},
			"generated_by":    {"type": "keyword"},
			"created_at":      {"type": "date"},
			"hit_count":       {"type": "integer"},
			"ttl_expires":     {"type": "date"}
		}
	}
}`

// DocumentsMapping defines the ES index mapping for RAG document chunks.
const DocumentsMapping = `{
	"mappings": {
		"properties": {
			"title":             {"type": "text"},
			"content":           {"type": "text"},
			"content_embedding": {"type": "dense_vector", "dims": 1536, "similarity": "cosine"},
			"source":            {"type": "keyword"},
			"category":          {"type": "keyword"},
			"chunk_index":       {"type": "integer"},
			"parent_doc_id":     {"type": "keyword"},
			"hana_table":        {"type": "keyword"},
			"last_synced_at":    {"type": "date"}
		}
	}
}`

// BusinessEntityMapping returns the ES index mapping for a business entity type.
func BusinessEntityMapping(entityType string) string {
	return fmt.Sprintf(`{
		"mappings": {
			"properties": {
				"hana_key":        {"type": "keyword"},
				"entity_type":     {"type": "keyword"},
				"fields":          {"type": "object", "dynamic": true},
				"display_text":    {"type": "text"},
				"last_synced_at":  {"type": "date"},
				"hana_changed_at": {"type": "date"}
			}
		}
	}`)
}

// EnsureIndex creates an index with the given mapping if it does not already exist.
func (c *Client) EnsureIndex(ctx context.Context, name string, mapping string) error {
	res, err := c.es.Indices.Exists([]string{name})
	if err != nil {
		return fmt.Errorf("failed to check index %s: %w", name, err)
	}
	defer res.Body.Close()

	if res.StatusCode == 200 {
		return nil // already exists
	}

	res, err = c.es.Indices.Create(name, c.es.Indices.Create.WithBody(strings.NewReader(mapping)))
	if err != nil {
		return fmt.Errorf("failed to create index %s: %w", name, err)
	}
	defer res.Body.Close()

	if res.IsError() {
		return fmt.Errorf("error creating index %s: %s", name, res.String())
	}
	return nil
}
