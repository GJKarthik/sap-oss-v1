// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
// Package es — hybrid BM25 + kNN retrieval wrapper.
//
// HybridSearcher executes Elasticsearch's native hybrid search (sub_searches +
// rank_constant_score / rrf) combining BM25 full-text and kNN dense-vector
// retrieval in a single round-trip.  When no query embedding is provided it
// falls back to BM25-only.
package es

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/elastic/go-elasticsearch/v8"
)

// HitDoc is a single document returned by a hybrid search.
type HitDoc struct {
	Title   string  `json:"title"`
	Content string  `json:"content"`
	Source  string  `json:"source"`
	Score   float64 `json:"score"`
}

// HybridSearchOptions configures a single hybrid search call.
type HybridSearchOptions struct {
	// Index is the ES index to search (default: "documents").
	Index string
	// TopK is the number of results to return (default: 5).
	TopK int
	// KNNWeight is the reciprocal-rank-fusion weight for the kNN sub-search (0–1, default 0.7).
	KNNWeight float64
	// BM25Weight is the RRF weight for the BM25 sub-search (0–1, default 0.3).
	BM25Weight float64
	// QueryEmbedding is the dense vector for kNN retrieval.
	// When nil, only BM25 is used.
	QueryEmbedding []float32
	// EmbeddingField is the dense_vector field name (default: "content_embedding").
	EmbeddingField string
	// ContentField is the text field for BM25 (default: "content").
	ContentField string
}

func (o *HybridSearchOptions) defaults() {
	if o.Index == "" {
		o.Index = "documents"
	}
	if o.TopK == 0 {
		o.TopK = 5
	}
	if o.KNNWeight == 0 {
		o.KNNWeight = 0.7
	}
	if o.BM25Weight == 0 {
		o.BM25Weight = 0.3
	}
	if o.EmbeddingField == "" {
		o.EmbeddingField = "content_embedding"
	}
	if o.ContentField == "" {
		o.ContentField = "content"
	}
}

// HybridSearch executes a BM25 + kNN hybrid search against Elasticsearch.
// When opts.QueryEmbedding is nil it falls back to BM25-only retrieval.
// Returns the matched documents and the top normalised score (0–100).
func HybridSearch(ctx context.Context, es *elasticsearch.Client, queryText string, opts HybridSearchOptions) ([]HitDoc, int64, error) {
	opts.defaults()

	var body map[string]interface{}

	if len(opts.QueryEmbedding) > 0 {
		// Hybrid: BM25 + kNN via Elasticsearch sub_searches + rrf
		embedding := make([]interface{}, len(opts.QueryEmbedding))
		for i, v := range opts.QueryEmbedding {
			embedding[i] = v
		}
		body = map[string]interface{}{
			"sub_searches": []interface{}{
				map[string]interface{}{
					"query": map[string]interface{}{
						"match": map[string]interface{}{
							opts.ContentField: map[string]interface{}{
								"query": queryText,
								"boost": opts.BM25Weight,
							},
						},
					},
				},
				map[string]interface{}{
					"knn": map[string]interface{}{
						"field":          opts.EmbeddingField,
						"query_vector":   embedding,
						"k":              opts.TopK,
						"num_candidates": opts.TopK * 10,
						"boost":          opts.KNNWeight,
					},
				},
			},
			"rank": map[string]interface{}{
				"rrf": map[string]interface{}{
					"window_size": opts.TopK * 4,
					"rank_constant": 60,
				},
			},
			"size": opts.TopK,
		}
	} else {
		// BM25-only fallback
		body = map[string]interface{}{
			"query": map[string]interface{}{
				"match": map[string]interface{}{
					opts.ContentField: queryText,
				},
			},
			"size": opts.TopK,
		}
	}

	var buf bytes.Buffer
	if err := json.NewEncoder(&buf).Encode(body); err != nil {
		return nil, 0, fmt.Errorf("hybrid search: encode body: %w", err)
	}

	res, err := es.Search(
		es.Search.WithContext(ctx),
		es.Search.WithIndex(opts.Index),
		es.Search.WithBody(&buf),
	)
	if err != nil {
		return nil, 0, fmt.Errorf("hybrid search: ES request: %w", err)
	}
	defer res.Body.Close()

	if res.IsError() {
		body, _ := io.ReadAll(res.Body)
		return nil, 0, fmt.Errorf("hybrid search: ES error %s: %s", res.Status(), body)
	}

	var esResp struct {
		Hits struct {
			Hits []struct {
				Score  float64 `json:"_score"`
				Source struct {
					Title   string `json:"title"`
					Content string `json:"content"`
					Source  string `json:"source"`
				} `json:"_source"`
			} `json:"hits"`
		} `json:"hits"`
	}
	if err := json.NewDecoder(res.Body).Decode(&esResp); err != nil {
		return nil, 0, fmt.Errorf("hybrid search: decode response: %w", err)
	}

	docs := make([]HitDoc, 0, len(esResp.Hits.Hits))
	var topScore float64
	for _, h := range esResp.Hits.Hits {
		if h.Score > topScore {
			topScore = h.Score
		}
		docs = append(docs, HitDoc{
			Title:   h.Source.Title,
			Content: h.Source.Content,
			Source:  h.Source.Source,
			Score:   h.Score,
		})
	}

	// Normalise to 0–100 integer
	score := int64(topScore * 100)
	if score > 100 {
		score = 100
	}
	return docs, score, nil
}

