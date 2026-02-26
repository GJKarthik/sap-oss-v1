// Package server implements the gRPC service for the Mangle Query Service.
package server

import (
	"context"
	"time"

	"github.com/elastic/go-elasticsearch/v8"

	pb "github.com/sap-oss/mangle-query-service/api/gen"
	"github.com/sap-oss/mangle-query-service/internal/engine"
	"github.com/sap-oss/mangle-query-service/internal/predicates"
)

// GRPCServer implements the QueryService gRPC interface.
type GRPCServer struct {
	pb.UnimplementedQueryServiceServer
	engine *engine.MangleEngine
}

// NewGRPCServer creates a GRPCServer backed by a MangleEngine loaded from rulesDir.
// If esClient is non-nil, ES predicates are registered as external callbacks.
func NewGRPCServer(rulesDir string, esClient *elasticsearch.Client) (*GRPCServer, error) {
	eng, err := engine.New(rulesDir)
	if err != nil {
		return nil, err
	}

	if esClient != nil {
		eng.RegisterPredicate("es_cache_lookup", 3, &predicates.ESCachePredicate{ES: esClient})
		eng.RegisterPredicate("es_hybrid_search", 3, &predicates.ESHybridPredicate{ES: esClient})
		eng.RegisterPredicate("es_search", 4, &predicates.ESBusinessPredicate{ES: esClient})
		if err := eng.Reload(); err != nil {
			return nil, err
		}
	}

	return &GRPCServer{engine: eng}, nil
}

func (s *GRPCServer) Resolve(ctx context.Context, req *pb.ResolveRequest) (*pb.ResolveResponse, error) {
	start := time.Now()

	result, err := s.engine.Resolve(req.Query)
	if err != nil {
		return nil, err
	}

	sources := make([]*pb.Source, len(result.Sources))
	for i, src := range result.Sources {
		sources[i] = &pb.Source{
			Title:   src.Title,
			Content: src.Content,
			Origin:  src.Origin,
			Score:   float32(src.Score),
		}
	}

	return &pb.ResolveResponse{
		Answer:        result.Answer,
		Path:          result.Path,
		Confidence:    float32(result.Confidence),
		Sources:       sources,
		LatencyMs:     time.Since(start).Milliseconds(),
		CorrelationId: req.CorrelationId,
	}, nil
}

func (s *GRPCServer) Health(ctx context.Context, req *pb.HealthRequest) (*pb.HealthResponse, error) {
	return &pb.HealthResponse{
		Status: "healthy",
		Components: map[string]string{
			"mangle_engine": "healthy",
		},
	}, nil
}

func (s *GRPCServer) SyncEntity(ctx context.Context, req *pb.SyncEntityRequest) (*pb.SyncEntityResponse, error) {
	// Stub — implemented in Phase E
	return &pb.SyncEntityResponse{Success: true}, nil
}
