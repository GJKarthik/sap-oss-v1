package es

import (
	"testing"
)

func TestNewClient(t *testing.T) {
	client, err := NewClient("http://localhost:9200")
	if err != nil {
		t.Fatalf("failed to create client: %v", err)
	}
	if client == nil {
		t.Fatal("client is nil")
	}
}
