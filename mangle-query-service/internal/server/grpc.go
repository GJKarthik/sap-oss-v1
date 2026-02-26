// Package server implements the gRPC service for the Mangle Query Service.
package server

import (
	"context"
	"time"

	"github.com/elastic/go-elasticsearch/v8"

	pb "github.com/sap-oss/mangle-query-service/api/gen"
	"github.com/sap-oss/mangle-query-service/internal/engine"
	"github.com/sap-oss/mangle-query-service/internal/predicates"
	"github.com/sap-oss/mangle-query-service/internal/sync"
)

// GRPCServer implements the QueryService gRPC interface.
type GRPCServer struct {
	pb.UnimplementedQueryServiceServer
	engine       *engine.MangleEngine
	cdcListener  *sync.CDCListener
	cacheManager *sync.CacheManager
}

// ServerOptions holds optional dependencies for GRPCServer.
type ServerOptions struct {
	ESClient   *elasticsearch.Client
	MCPAddress string
	MCPToken   string
}

// NewGRPCServer creates a GRPCServer backed by a MangleEngine loaded from rulesDir.
func NewGRPCServer(rulesDir string, opts *ServerOptions) (*GRPCServer, error) {
	eng, err := engine.New(rulesDir)
	if err != nil {
		return nil, err
	}

	srv := &GRPCServer{engine: eng}

	if opts != nil {
		// Register ES predicates
		if opts.ESClient != nil {
			eng.RegisterPredicate("es_cache_lookup", 3, &predicates.ESCachePredicate{ES: opts.ESClient})
			eng.RegisterPredicate("es_hybrid_search", 3, &predicates.ESHybridPredicate{ES: opts.ESClient})
			eng.RegisterPredicate("es_search", 4, &predicates.ESBusinessPredicate{ES: opts.ESClient})

			srv.cdcListener = sync.NewCDCListener(opts.ESClient)
			srv.cacheManager = sync.NewCacheManager(opts.ESClient)
		}

		// Register MCP predicates (heuristic fallback if no MCP address)
		eng.RegisterPredicate("classify_query", 3, &predicates.MCPClassifyPredicate{
			MCPAddress: opts.MCPAddress, AuthToken: opts.MCPToken,
		})
		eng.RegisterPredicate("extract_entities", 3, &predicates.MCPEntitiesPredicate{
			MCPAddress: opts.MCPAddress, AuthToken: opts.MCPToken,
		})
		eng.RegisterPredicate("rerank", 3, &predicates.MCPRerankPredicate{
			MCPAddress: opts.MCPAddress, AuthToken: opts.MCPToken,
		})
		eng.RegisterPredicate("llm_generate", 3, &predicates.MCPLLMPredicate{
			MCPAddress: opts.MCPAddress, AuthToken: opts.MCPToken,
		})

		if err := eng.Reload(); err != nil {
			return nil, err
		}
	}

	return srv, nil
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

	// Cache LLM-generated answers for future reuse
	if s.cacheManager != nil && (result.Path == "llm" || result.Path == "llm_fallback") {
		_ = s.cacheManager.StoreAnswer(ctx, req.Query, result.Answer, result.Path)
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
	if s.cdcListener == nil {
		return &pb.SyncEntityResponse{Success: false, Error: "sync not configured"}, nil
	}

	entityRefs, err := s.cdcListener.HandleChange(ctx, req.EntityType, req.EntityId, req.Operation, req.PayloadJson)
	if err != nil {
		return &pb.SyncEntityResponse{Success: false, Error: err.Error()}, nil
	}

	// Invalidate cached answers referencing the changed entity
	if s.cacheManager != nil && len(entityRefs) > 0 {
		_, _ = s.cacheManager.InvalidateByEntity(ctx, entityRefs)
	}

	return &pb.SyncEntityResponse{Success: true}, nil
}
