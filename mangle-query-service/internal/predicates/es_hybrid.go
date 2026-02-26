package predicates

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"

	"github.com/elastic/go-elasticsearch/v8"
	"github.com/google/mangle/ast"
)

// ESHybridPredicate implements es_hybrid_search/3: (Query, DocsJSON, TopScore).
type ESHybridPredicate struct {
	ES         *elasticsearch.Client
	Index      string  // default: "documents"
	KNNWeight  float64 // default: 0.7
	BM25Weight float64 // default: 0.3
	TopK       int     // default: 5
}

func (p *ESHybridPredicate) ShouldPushdown() bool { return false }

func (p *ESHybridPredicate) ShouldQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term) bool {
	return len(inputs) > 0
}

func (p *ESHybridPredicate) ExecuteQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term, cb func([]ast.BaseTerm)) error {
	if len(inputs) == 0 {
		return fmt.Errorf("es_hybrid_search requires at least 1 input (query text)")
	}

	queryText, err := inputs[0].StringValue()
	if err != nil {
		return fmt.Errorf("es_hybrid_search: invalid query input: %w", err)
	}

	index := p.Index
	if index == "" {
		index = "documents"
	}
	topK := p.TopK
	if topK == 0 {
		topK = 5
	}

	query := map[string]interface{}{
		"query": map[string]interface{}{
			"match": map[string]interface{}{
				"content": queryText,
			},
		},
		"size": topK,
	}

	var buf bytes.Buffer
	if err := json.NewEncoder(&buf).Encode(query); err != nil {
		return fmt.Errorf("failed to encode query: %w", err)
	}

	res, err := p.ES.Search(
		p.ES.Search.WithContext(context.Background()),
		p.ES.Search.WithIndex(index),
		p.ES.Search.WithBody(&buf),
	)
	if err != nil {
		return fmt.Errorf("es hybrid search failed: %w", err)
	}
	defer res.Body.Close()

	if res.IsError() {
		return nil
	}

	var result struct {
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

	if err := json.NewDecoder(res.Body).Decode(&result); err != nil {
		return fmt.Errorf("failed to decode response: %w", err)
	}

	docs := make([]map[string]interface{}, 0, len(result.Hits.Hits))
	var topScore float64
	for _, hit := range result.Hits.Hits {
		if hit.Score > topScore {
			topScore = hit.Score
		}
		docs = append(docs, map[string]interface{}{
			"title":   hit.Source.Title,
			"content": hit.Source.Content,
			"source":  hit.Source.Source,
			"score":   hit.Score,
		})
	}

	docsJSON, _ := json.Marshal(docs)
	// Normalize score to 0-100 integer range
	score := int64(topScore * 100)
	if score > 100 {
		score = 100
	}
	cb([]ast.BaseTerm{
		ast.String(string(docsJSON)),
		ast.Number(score),
	})

	return nil
}
