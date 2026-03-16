// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
// Package server implements the gRPC service for the Mangle Query Service.
package server

import (
	"context"
	"os"
	"strings"
	"time"

	"github.com/elastic/go-elasticsearch/v8"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	pb "github.com/sap-oss/mangle-query-service/api/gen"
	"github.com/sap-oss/mangle-query-service/internal/engine"
	"github.com/sap-oss/mangle-query-service/internal/predicates"
	"github.com/sap-oss/mangle-query-service/internal/resilience"
	"github.com/sap-oss/mangle-query-service/internal/sync"
)

const maxResolveQueryChars = 16 * 1024
const maxCorrelationIDChars = 256
const maxEntityRefChars = 256
const maxSyncPayloadChars = 256 * 1024

// GRPCServer implements the QueryService gRPC interface.
type GRPCServer struct {
	pb.UnimplementedQueryServiceServer
	engine       *engine.MangleEngine
	cdcListener  *sync.CDCListener
	cacheManager *sync.CacheManager
	breakers     *resilience.BreakerRegistry
	metrics      *resilience.Metrics
	userRolePred *predicates.CurrentUserRolePredicate
}

// ServerOptions holds optional dependencies for GRPCServer.
type ServerOptions struct {
	ESClient   *elasticsearch.Client
	MCPAddress string
	MCPToken   string
}

// productionRules is the ordered list of rule files loaded in production.
// es_domain.mg is appended last so its facts can reference predicates
// declared in the earlier governance and routing files.
var productionRules = []string{
	"routing.mg",
	"governance.mg",
	"analytics_routing.mg",
	"hana_vector.mg",
	"rag_enrichment.mg",
	"model_registry.mg",
	"agent_classification.mg",
	"graph_rag.mg",
	"es_domain.mg",
}

// NewGRPCServer creates a GRPCServer backed by a MangleEngine loaded from rulesDir.
func NewGRPCServer(rulesDir string, opts *ServerOptions) (*GRPCServer, error) {
	eng, err := engine.NewWithRules(rulesDir, productionRules...)
	if err != nil {
		return nil, err
	}

	srv := &GRPCServer{
		engine:   eng,
		breakers: resilience.NewBreakerRegistry(),
		metrics:  resilience.NewMetrics(),
	}

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
	}

	// Register built-in governance / GDPR predicates (always available)
	srv.userRolePred = &predicates.CurrentUserRolePredicate{}
	eng.RegisterPredicate("current_user_role", 1, srv.userRolePred)
	eng.RegisterPredicate("current_date", 1, &predicates.CurrentDatePredicate{})
	eng.RegisterPredicate("environment", 1, &predicates.EnvironmentPredicate{})
	eng.RegisterPredicate("consent_verified", 2, &predicates.ConsentVerifiedPredicate{
		ConsentServiceURL: os.Getenv("MQS_CONSENT_SERVICE_URL"),
	})
	eng.RegisterPredicate("log_audit", 2, &predicates.LogAuditPredicate{})

	if opts != nil {
		if err := eng.Reload(); err != nil {
			return nil, err
		}
	}

	return srv, nil
}

func (s *GRPCServer) Resolve(ctx context.Context, req *pb.ResolveRequest) (*pb.ResolveResponse, error) {
	if err := validateResolveRequest(req); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, status.Errorf(codes.Canceled, "request canceled: %v", err)
	}

	start := time.Now()

	// Check circuit breaker for the resolve path
	cb := s.breakers.Get("resolve")
	if !cb.Allow() {
		s.metrics.RecordError()
		return nil, status.Error(codes.Unavailable, "resolve temporarily unavailable")
	}

	result, err := s.engine.Resolve(req.Query)
	if err != nil {
		cb.RecordFailure()
		s.metrics.RecordError()
		return nil, status.Errorf(codes.Internal, "resolve failed: %v", err)
	}
	cb.RecordSuccess()

	latencyMs := time.Since(start).Milliseconds()
	s.metrics.RecordResolve(result.Path, latencyMs)

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
		LatencyMs:     latencyMs,
		CorrelationId: req.CorrelationId,
	}, nil
}

func (s *GRPCServer) Health(ctx context.Context, req *pb.HealthRequest) (*pb.HealthResponse, error) {
	if err := ctx.Err(); err != nil {
		return nil, status.Errorf(codes.Canceled, "request canceled: %v", err)
	}

	components := map[string]string{
		"mangle_engine": "healthy",
	}
	metrics := make(map[string]float32)

	// Report circuit breaker states
	for _, cb := range s.breakers.All() {
		components["breaker_"+cb.Name()] = cb.GetState().String()
	}

	// Report key metrics
	snap := s.metrics.Snapshot()
	for k, v := range snap {
		metrics[k] = float32(v)
	}

	status := "healthy"
	for _, cb := range s.breakers.All() {
		if cb.GetState() == resilience.StateOpen {
			status = "degraded"
			break
		}
	}

	return &pb.HealthResponse{
		Status:     status,
		Components: components,
		Metrics:    metrics,
	}, nil
}

func (s *GRPCServer) SyncEntity(ctx context.Context, req *pb.SyncEntityRequest) (*pb.SyncEntityResponse, error) {
	op, err := validateSyncEntityRequest(req)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, status.Errorf(codes.Canceled, "request canceled: %v", err)
	}

	if s.cdcListener == nil {
		return &pb.SyncEntityResponse{Success: false, Error: "sync not configured"}, nil
	}

	entityRefs, err := s.cdcListener.HandleChange(ctx, req.EntityType, req.EntityId, op, req.PayloadJson)
	if err != nil {
		return &pb.SyncEntityResponse{Success: false, Error: err.Error()}, nil
	}

	// Invalidate cached answers referencing the changed entity
	if s.cacheManager != nil && len(entityRefs) > 0 {
		_, _ = s.cacheManager.InvalidateByEntity(ctx, entityRefs)
	}

	return &pb.SyncEntityResponse{Success: true}, nil
}

func validateResolveRequest(req *pb.ResolveRequest) error {
	if req == nil {
		return status.Error(codes.InvalidArgument, "request is required")
	}
	if len(req.CorrelationId) > maxCorrelationIDChars {
		return status.Errorf(codes.InvalidArgument, "correlation_id exceeds maximum length of %d characters", maxCorrelationIDChars)
	}
	query := strings.TrimSpace(req.Query)
	if query == "" {
		return status.Error(codes.InvalidArgument, "query is required")
	}
	if len(query) > maxResolveQueryChars {
		return status.Errorf(codes.InvalidArgument, "query exceeds maximum length of %d characters", maxResolveQueryChars)
	}
	return nil
}

func validateSyncEntityRequest(req *pb.SyncEntityRequest) (string, error) {
	if req == nil {
		return "", status.Error(codes.InvalidArgument, "request is required")
	}
	entityType := strings.TrimSpace(req.EntityType)
	if entityType == "" {
		return "", status.Error(codes.InvalidArgument, "entity_type is required")
	}
	entityID := strings.TrimSpace(req.EntityId)
	if entityID == "" {
		return "", status.Error(codes.InvalidArgument, "entity_id is required")
	}
	if len(entityType) > maxEntityRefChars {
		return "", status.Errorf(codes.InvalidArgument, "entity_type exceeds maximum length of %d characters", maxEntityRefChars)
	}
	if len(entityID) > maxEntityRefChars {
		return "", status.Errorf(codes.InvalidArgument, "entity_id exceeds maximum length of %d characters", maxEntityRefChars)
	}
	op := strings.ToLower(strings.TrimSpace(req.Operation))
	switch op {
	case "insert", "update":
		if strings.TrimSpace(req.PayloadJson) == "" {
			return "", status.Error(codes.InvalidArgument, "payload_json is required for insert/update")
		}
		if len(req.PayloadJson) > maxSyncPayloadChars {
			return "", status.Errorf(codes.InvalidArgument, "payload_json exceeds maximum length of %d characters", maxSyncPayloadChars)
		}
	case "delete":
		// payload is optional for delete
		if len(req.PayloadJson) > maxSyncPayloadChars {
			return "", status.Errorf(codes.InvalidArgument, "payload_json exceeds maximum length of %d characters", maxSyncPayloadChars)
		}
	default:
		return "", status.Error(codes.InvalidArgument, "operation must be one of: insert, update, delete")
	}
	return op, nil
}
