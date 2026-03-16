// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
// Package predicates implements Mangle ExternalPredicateCallback for ES queries.
package predicates

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"

	"github.com/elastic/go-elasticsearch/v8"
	"github.com/google/mangle/ast"
)

// ESCachePredicate implements es_cache_lookup/3: (Query, Answer, Score).
type ESCachePredicate struct {
	ES    *elasticsearch.Client
	Index string // default: "cache-qa"
}

func (p *ESCachePredicate) ShouldPushdown() bool { return false }

func (p *ESCachePredicate) ShouldQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term) bool {
	return len(inputs) > 0
}

func (p *ESCachePredicate) ExecuteQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term, cb func([]ast.BaseTerm)) error {
	if len(inputs) == 0 {
		return fmt.Errorf("es_cache_lookup requires at least 1 input (query text)")
	}

	queryText, err := inputs[0].StringValue()
	if err != nil {
		return fmt.Errorf("es_cache_lookup: invalid query input: %w", err)
	}

	index := p.Index
	if index == "" {
		index = "cache-qa"
	}

	query := map[string]interface{}{
		"query": map[string]interface{}{
			"match": map[string]interface{}{
				"query_text": queryText,
			},
		},
		"size": 1,
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
		return fmt.Errorf("es cache search failed: %w", err)
	}
	defer res.Body.Close()

	if res.IsError() {
		return nil // no results, not an error
	}

	var result struct {
		Hits struct {
			Hits []struct {
				Score  float64 `json:"_score"`
				Source struct {
					AnswerText string `json:"answer_text"`
				} `json:"_source"`
			} `json:"hits"`
		} `json:"hits"`
	}

	if err := json.NewDecoder(res.Body).Decode(&result); err != nil {
		return fmt.Errorf("failed to decode response: %w", err)
	}

	for _, hit := range result.Hits.Hits {
		// Normalize score to 0-100 integer range for Mangle rules
		score := int64(hit.Score * 100)
		if score > 100 {
			score = 100
		}
		cb([]ast.BaseTerm{
			ast.String(hit.Source.AnswerText),
			ast.Number(score),
		})
	}

	return nil
}
