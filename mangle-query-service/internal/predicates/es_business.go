// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package predicates

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"

	"github.com/elastic/go-elasticsearch/v8"
	"github.com/google/mangle/ast"
)

// ESBusinessPredicate implements es_search/4: (EntityType, Key, DisplayText, Score).
type ESBusinessPredicate struct {
	ES *elasticsearch.Client
}

func (p *ESBusinessPredicate) ShouldPushdown() bool { return false }

func (p *ESBusinessPredicate) ShouldQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term) bool {
	return len(inputs) >= 2
}

func (p *ESBusinessPredicate) ExecuteQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term, cb func([]ast.BaseTerm)) error {
	if len(inputs) < 2 {
		return fmt.Errorf("es_search requires 2 inputs (entity_type, key)")
	}

	entityType, err := inputs[0].StringValue()
	if err != nil {
		return fmt.Errorf("es_search: invalid entity_type: %w", err)
	}
	key, err := inputs[1].StringValue()
	if err != nil {
		return fmt.Errorf("es_search: invalid key: %w", err)
	}

	index := fmt.Sprintf("business-%s", entityType)

	// Search by hana_key or display_text
	query := map[string]interface{}{
		"query": map[string]interface{}{
			"bool": map[string]interface{}{
				"should": []map[string]interface{}{
					{"term": map[string]interface{}{"hana_key": key}},
					{"match": map[string]interface{}{"display_text": key}},
				},
			},
		},
		"size": 5,
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
		return fmt.Errorf("es business search failed: %w", err)
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
					DisplayText string `json:"display_text"`
				} `json:"_source"`
			} `json:"hits"`
		} `json:"hits"`
	}

	if err := json.NewDecoder(res.Body).Decode(&result); err != nil {
		return fmt.Errorf("failed to decode response: %w", err)
	}

	for _, hit := range result.Hits.Hits {
		score := int64(hit.Score * 100)
		if score > 100 {
			score = 100
		}
		cb([]ast.BaseTerm{
			ast.String(hit.Source.DisplayText),
			ast.Number(score),
		})
	}

	return nil
}
