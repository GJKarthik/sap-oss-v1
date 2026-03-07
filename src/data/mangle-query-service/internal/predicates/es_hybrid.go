// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package predicates

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/elastic/go-elasticsearch/v8"
	"github.com/google/mangle/ast"

	"github.com/sap-oss/mangle-query-service/internal/es"
)

// ESHybridPredicate implements es_hybrid_search/3: (Query, DocsJSON, TopScore).
// It delegates to es.HybridSearch which executes a BM25 + kNN hybrid query
// using Elasticsearch's native sub_searches + RRF ranking.
type ESHybridPredicate struct {
	ES         *elasticsearch.Client
	Index      string  // default: "documents"
	KNNWeight  float64 // default: 0.7
	BM25Weight float64 // default: 0.3
	TopK       int     // default: 5
	// EmbeddingFn optionally provides a query embedding for kNN retrieval.
	// When nil, BM25-only retrieval is used.
	EmbeddingFn func(ctx context.Context, text string) ([]float32, error)
}

func (p *ESHybridPredicate) ShouldPushdown() bool { return false }

func (p *ESHybridPredicate) ShouldQuery(inputs []ast.Constant, _ []ast.BaseTerm, _ []ast.Term) bool {
	return len(inputs) > 0
}

func (p *ESHybridPredicate) ExecuteQuery(inputs []ast.Constant, _ []ast.BaseTerm, _ []ast.Term, cb func([]ast.BaseTerm)) error {
	if len(inputs) == 0 {
		return fmt.Errorf("es_hybrid_search requires at least 1 input (query text)")
	}

	queryText, err := inputs[0].StringValue()
	if err != nil {
		return fmt.Errorf("es_hybrid_search: invalid query input: %w", err)
	}

	ctx := context.Background()

	opts := es.HybridSearchOptions{
		Index:      p.Index,
		TopK:       p.TopK,
		KNNWeight:  p.KNNWeight,
		BM25Weight: p.BM25Weight,
	}

	// Optionally enrich with a query embedding for kNN retrieval
	if p.EmbeddingFn != nil {
		embedding, embErr := p.EmbeddingFn(ctx, queryText)
		if embErr == nil {
			opts.QueryEmbedding = embedding
		}
		// On embedding error we fall back to BM25-only (non-fatal)
	}

	docs, score, err := es.HybridSearch(ctx, p.ES, queryText, opts)
	if err != nil {
		// Non-fatal: return empty result so Mangle can try other paths
		cb([]ast.BaseTerm{ast.String("[]"), ast.Number(0)})
		return nil
	}

	// Serialise docs to JSON for Mangle
	type docJSON struct {
		Title   string  `json:"title"`
		Content string  `json:"content"`
		Source  string  `json:"source"`
		Score   float64 `json:"score"`
	}
	out := make([]docJSON, len(docs))
	for i, d := range docs {
		out[i] = docJSON{Title: d.Title, Content: d.Content, Source: d.Source, Score: d.Score}
	}
	docsJSON, _ := json.Marshal(out)

	cb([]ast.BaseTerm{
		ast.String(string(docsJSON)),
		ast.Number(score),
	})
	return nil
}
