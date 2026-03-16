// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
// Package es provides an Elasticsearch client and index management.
package es

import (
	"fmt"

	"github.com/elastic/go-elasticsearch/v8"
)

// Client wraps the Elasticsearch Go client.
type Client struct {
	es *elasticsearch.Client
}

// NewClient creates an ES Client connecting to the given address.
func NewClient(address string) (*Client, error) {
	cfg := elasticsearch.Config{
		Addresses: []string{address},
	}
	es, err := elasticsearch.NewClient(cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create ES client: %w", err)
	}
	return &Client{es: es}, nil
}

// Raw returns the underlying elasticsearch.Client for advanced operations.
func (c *Client) Raw() *elasticsearch.Client {
	return c.es
}
