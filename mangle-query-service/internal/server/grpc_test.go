package server

import (
	"context"
	"testing"

	pb "github.com/sap-oss/mangle-query-service/api/gen"
)

func TestResolveRPC(t *testing.T) {
	srv, err := NewGRPCServer("../../rules/")
	if err != nil {
		t.Fatalf("failed to create server: %v", err)
	}

	resp, err := srv.Resolve(context.Background(), &pb.ResolveRequest{
		Query:         "test query",
		CorrelationId: "test-123",
	})
	if err != nil {
		t.Fatalf("Resolve RPC failed: %v", err)
	}
	if resp.CorrelationId != "test-123" {
		t.Errorf("expected correlation_id 'test-123', got '%s'", resp.CorrelationId)
	}
	if resp.Path == "" {
		t.Error("expected non-empty path")
	}
}

func TestHealthRPC(t *testing.T) {
	srv, err := NewGRPCServer("../../rules/")
	if err != nil {
		t.Fatalf("failed to create server: %v", err)
	}

	resp, err := srv.Health(context.Background(), &pb.HealthRequest{})
	if err != nil {
		t.Fatalf("Health RPC failed: %v", err)
	}
	if resp.Status == "" {
		t.Error("expected non-empty status")
	}
}
