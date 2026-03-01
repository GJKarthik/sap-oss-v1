// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
package server

import (
	"context"
	"strings"
	"testing"

	pb "github.com/sap-oss/mangle-query-service/api/gen"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestResolveRPC(t *testing.T) {
	srv, err := NewGRPCServer("../../rules/", nil /* no opts */)
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
	srv, err := NewGRPCServer("../../rules/", nil /* no opts */)
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
	if len(resp.Metrics) == 0 {
		t.Fatal("expected non-empty metrics map")
	}
	if _, ok := resp.Metrics["total_requests"]; !ok {
		t.Error("expected total_requests metric in response")
	}
}

func TestResolveRPCRejectsEmptyQuery(t *testing.T) {
	srv, err := NewGRPCServer("../../rules/", nil /* no opts */)
	if err != nil {
		t.Fatalf("failed to create server: %v", err)
	}

	_, err = srv.Resolve(context.Background(), &pb.ResolveRequest{Query: "  "})
	if err == nil {
		t.Fatal("expected validation error for empty query")
	}
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("expected InvalidArgument, got %s", status.Code(err))
	}
}

func TestResolveRPCRejectsOverlongQuery(t *testing.T) {
	srv, err := NewGRPCServer("../../rules/", nil /* no opts */)
	if err != nil {
		t.Fatalf("failed to create server: %v", err)
	}

	tooLong := strings.Repeat("a", maxResolveQueryChars+1)
	_, err = srv.Resolve(context.Background(), &pb.ResolveRequest{Query: tooLong})
	if err == nil {
		t.Fatal("expected validation error for overlong query")
	}
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("expected InvalidArgument, got %s", status.Code(err))
	}
}

func TestResolveRPCRejectsOverlongCorrelationID(t *testing.T) {
	srv, err := NewGRPCServer("../../rules/", nil /* no opts */)
	if err != nil {
		t.Fatalf("failed to create server: %v", err)
	}

	_, err = srv.Resolve(context.Background(), &pb.ResolveRequest{
		Query:         "ok",
		CorrelationId: strings.Repeat("c", maxCorrelationIDChars+1),
	})
	if err == nil {
		t.Fatal("expected validation error for overlong correlation id")
	}
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("expected InvalidArgument, got %s", status.Code(err))
	}
}

func TestSyncEntityRejectsInvalidOperation(t *testing.T) {
	srv, err := NewGRPCServer("../../rules/", nil /* no opts */)
	if err != nil {
		t.Fatalf("failed to create server: %v", err)
	}

	_, err = srv.SyncEntity(context.Background(), &pb.SyncEntityRequest{
		EntityType: "order",
		EntityId:   "42",
		Operation:  "bad-op",
	})
	if err == nil {
		t.Fatal("expected validation error for invalid operation")
	}
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("expected InvalidArgument, got %s", status.Code(err))
	}
}

func TestSyncEntityRejectsOverlongPayload(t *testing.T) {
	srv, err := NewGRPCServer("../../rules/", nil /* no opts */)
	if err != nil {
		t.Fatalf("failed to create server: %v", err)
	}

	_, err = srv.SyncEntity(context.Background(), &pb.SyncEntityRequest{
		EntityType: "order",
		EntityId:   "42",
		Operation:  "update",
		PayloadJson: strings.Repeat("x", maxSyncPayloadChars+1),
	})
	if err == nil {
		t.Fatal("expected validation error for overlong payload")
	}
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("expected InvalidArgument, got %s", status.Code(err))
	}
}
