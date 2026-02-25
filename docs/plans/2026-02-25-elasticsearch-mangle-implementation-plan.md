# Elasticsearch + Mangle Query Service Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a unified query resolution service where Elasticsearch handles 80% of prompt load without LLM, orchestrated by Mangle as the central routing/data-unification brain.

**Architecture:** A Go microservice (Mangle Query Service) wraps the Mangle logic engine with external predicates for Elasticsearch, HANA, and hana_ai (via MCP). cap-llm-plugin calls this service via gRPC. Routing rules are declarative Mangle `.mg` files. HANA syncs to ES via batch ETL + real-time CDC.

**Tech Stack:** Go 1.23 (Mangle engine + gRPC server), Python (hana_ai MCP server), TypeScript (cap-llm-plugin gRPC client), Elasticsearch 8.x (@elastic/elasticsearch), Protocol Buffers (gRPC contract).

---

## Phase Overview

| Phase | Tasks | What it delivers |
|---|---|---|
| **A: Mangle Query Service scaffold** | 1-5 | Go project, gRPC API, Mangle engine wired up, health endpoint |
| **B: Elasticsearch predicates** | 6-10 | ES client, cache-qa/business/documents indices, kNN+BM25 hybrid search |
| **C: Routing rules** | 11-14 | `.mg` rule files for classification, resolution, caching, fallback |
| **D: hana_ai MCP integration** | 15-18 | Python MCP server with adapted classifier/extractor/reranker, Go MCP predicates |
| **E: HANA sync pipeline** | 19-22 | Batch ETL + CDC listener, cache invalidation |
| **F: cap-llm-plugin integration** | 23-25 | gRPC client in TypeScript, resolveQuery() method, CDS endpoint |
| **G: Observability + resilience** | 26-28 | Circuit breakers, Prometheus metrics, OTel traces, health rules |
| **H: Integration + E2E tests** | 29-31 | Mangle+ES integration tests, 80/20 validation, E2E scenarios |

---

## Phase A: Mangle Query Service Scaffold

### Task 1: Initialize Go project

**Files:**
- Create: `mangle-query-service/go.mod`
- Create: `mangle-query-service/cmd/server/main.go`
- Create: `mangle-query-service/internal/config/config.go`

**Step 1: Create project directory and go.mod**

```bash
mkdir -p /Users/user/Documents/sap-oss/mangle-query-service/cmd/server
mkdir -p /Users/user/Documents/sap-oss/mangle-query-service/internal/config
cd /Users/user/Documents/sap-oss/mangle-query-service
go mod init github.com/sap-oss/mangle-query-service
```

**Step 2: Add Mangle as dependency**

```bash
cd /Users/user/Documents/sap-oss/mangle-query-service
go mod edit -require github.com/google/mangle@v0.0.0
go mod edit -replace github.com/google/mangle=../mangle-main
```

**Step 3: Write config.go**

```go
// internal/config/config.go
package config

import (
	"encoding/json"
	"os"
)

type Config struct {
	GRPCPort       int    `json:"grpc_port"`
	HTTPPort       int    `json:"http_port"`
	RulesDir       string `json:"rules_dir"`
	ESAddress      string `json:"es_address"`
	HANAHost       string `json:"hana_host"`
	HANAPort       int    `json:"hana_port"`
	HANAUser       string `json:"hana_user"`
	HANAPassword   string `json:"hana_password"`
	MCPAddress     string `json:"mcp_address"`
	MCPAuthToken   string `json:"mcp_auth_token"`
}

func Load(path string) (*Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var cfg Config
	if err := json.NewDecoder(f).Decode(&cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func Default() *Config {
	return &Config{
		GRPCPort:   50051,
		HTTPPort:   8080,
		RulesDir:   "rules/",
		ESAddress:  "http://localhost:9200",
		MCPAddress: "http://localhost:8001/mcp",
	}
}
```

**Step 4: Write minimal main.go**

```go
// cmd/server/main.go
package main

import (
	"fmt"
	"log"
	"os"

	"github.com/sap-oss/mangle-query-service/internal/config"
)

func main() {
	cfgPath := os.Getenv("MQS_CONFIG")
	var cfg *config.Config
	if cfgPath != "" {
		var err error
		cfg, err = config.Load(cfgPath)
		if err != nil {
			log.Fatalf("failed to load config: %v", err)
		}
	} else {
		cfg = config.Default()
	}
	fmt.Printf("Mangle Query Service starting on gRPC port %d, HTTP port %d\n", cfg.GRPCPort, cfg.HTTPPort)
}
```

**Step 5: Verify build**

Run: `cd /Users/user/Documents/sap-oss/mangle-query-service && go build ./...`
Expected: Clean build, no errors.

**Step 6: Commit**

```bash
cd /Users/user/Documents/sap-oss
git add mangle-query-service/
git commit -m "feat: scaffold mangle-query-service Go project with config"
```

---

### Task 2: Define gRPC API contract

**Files:**
- Create: `mangle-query-service/api/proto/query.proto`
- Create: `mangle-query-service/api/proto/generate.sh`

**Step 1: Write protobuf definition**

```protobuf
// api/proto/query.proto
syntax = "proto3";

package mqs.v1;

option go_package = "github.com/sap-oss/mangle-query-service/api/gen";

service QueryService {
  rpc Resolve(ResolveRequest) returns (ResolveResponse);
  rpc Health(HealthRequest) returns (HealthResponse);
  rpc SyncEntity(SyncEntityRequest) returns (SyncEntityResponse);
}

message ResolveRequest {
  string query = 1;
  repeated float query_embedding = 2;
  string correlation_id = 3;
  map<string, string> metadata = 4;
}

message ResolveResponse {
  string answer = 1;
  string path = 2;            // "cache", "factual", "rag", "llm", "llm_fallback"
  float confidence = 3;
  repeated Source sources = 4;
  int64 latency_ms = 5;
  string correlation_id = 6;
}

message Source {
  string title = 1;
  string content = 2;
  string origin = 3;          // "es_cache", "es_business", "es_documents", "hana", "llm"
  float score = 4;
}

message HealthRequest {}

message HealthResponse {
  string status = 1;          // "healthy", "degraded", "unhealthy"
  map<string, string> components = 2;  // component -> status
  map<string, float> metrics = 3;
}

message SyncEntityRequest {
  string entity_type = 1;
  string entity_id = 2;
  string operation = 3;       // "insert", "update", "delete"
  string payload_json = 4;
}

message SyncEntityResponse {
  bool success = 1;
  string error = 2;
}
```

**Step 2: Write code generation script**

```bash
#!/bin/bash
# api/proto/generate.sh
set -e
mkdir -p ../gen
protoc --go_out=../gen --go_opt=paths=source_relative \
       --go-grpc_out=../gen --go-grpc_opt=paths=source_relative \
       query.proto
echo "Generated Go gRPC code in api/gen/"
```

**Step 3: Install protoc dependencies and generate**

```bash
cd /Users/user/Documents/sap-oss/mangle-query-service
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
mkdir -p api/gen
cd api/proto && chmod +x generate.sh && bash generate.sh
```

**Step 4: Add gRPC dependencies to go.mod**

```bash
cd /Users/user/Documents/sap-oss/mangle-query-service
go get google.golang.org/grpc
go get google.golang.org/protobuf
```

**Step 5: Verify generated code compiles**

Run: `cd /Users/user/Documents/sap-oss/mangle-query-service && go build ./...`
Expected: Clean build including generated gRPC code.

**Step 6: Commit**

```bash
cd /Users/user/Documents/sap-oss
git add mangle-query-service/api/
git commit -m "feat: define gRPC API contract for Mangle Query Service"
```

---

### Task 3: Wire Mangle engine into service

**Files:**
- Create: `mangle-query-service/internal/engine/engine.go`
- Create: `mangle-query-service/internal/engine/engine_test.go`

**Step 1: Write the failing test**

```go
// internal/engine/engine_test.go
package engine

import (
	"testing"
)

func TestNewMangleEngine(t *testing.T) {
	eng, err := New("../../rules/")
	if err != nil {
		t.Fatalf("failed to create engine: %v", err)
	}
	if eng == nil {
		t.Fatal("engine is nil")
	}
}

func TestResolveWithMockFacts(t *testing.T) {
	eng, err := New("../../rules/")
	if err != nil {
		t.Fatalf("failed to create engine: %v", err)
	}

	// Inject a mock cached answer
	err = eng.DefineFact(`es_cache_lookup("what is our return policy", "Our return policy allows 30-day returns.", 0.97).`)
	if err != nil {
		t.Fatalf("failed to define fact: %v", err)
	}

	result, err := eng.Resolve("what is our return policy")
	if err != nil {
		t.Fatalf("resolve failed: %v", err)
	}
	if result.Path != "cache" {
		t.Errorf("expected path 'cache', got '%s'", result.Path)
	}
	if result.Answer == "" {
		t.Error("expected non-empty answer")
	}
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/user/Documents/sap-oss/mangle-query-service && go test ./internal/engine/ -v`
Expected: FAIL — package does not exist.

**Step 3: Create rules directory with minimal routing rule**

```bash
mkdir -p /Users/user/Documents/sap-oss/mangle-query-service/rules
```

```prolog
# rules/routing.mg

# A query is cached if ES returns a match with score >= 0.95
is_cached(Query) :-
    es_cache_lookup(Query, _Answer, Score),
    Score >= 0.95.

# Resolution: cached path
resolve(Query, Answer, "cache", Score) :-
    is_cached(Query),
    es_cache_lookup(Query, Answer, Score).
```

**Step 4: Write engine.go**

```go
// internal/engine/engine.go
package engine

import (
	"fmt"
	"io"
	"os"
	"sync"

	"github.com/google/mangle/ast"
	mangleEngine "github.com/google/mangle/engine"
	"github.com/google/mangle/interpreter"
	"github.com/google/mangle/parse"
)

type Resolution struct {
	Answer     string
	Path       string
	Confidence float64
	Sources    []Source
}

type Source struct {
	Title   string
	Content string
	Origin  string
	Score   float64
}

type MangleEngine struct {
	mu          sync.RWMutex
	interp      *interpreter.Interpreter
	rulesDir    string
	predicates  map[ast.PredicateSym]mangleEngine.ExternalPredicateCallback
}

func New(rulesDir string) (*MangleEngine, error) {
	eng := &MangleEngine{
		rulesDir:   rulesDir,
		predicates: make(map[ast.PredicateSym]mangleEngine.ExternalPredicateCallback),
	}

	if err := eng.reload(); err != nil {
		return nil, fmt.Errorf("failed to load rules: %w", err)
	}
	return eng, nil
}

func (e *MangleEngine) reload() error {
	e.mu.Lock()
	defer e.mu.Unlock()

	e.interp = interpreter.New(io.Discard, e.rulesDir, nil)
	if err := e.interp.Load(e.rulesDir + "*.mg"); err != nil {
		return fmt.Errorf("failed to load rules from %s: %w", e.rulesDir, err)
	}
	return nil
}

func (e *MangleEngine) DefineFact(clauseText string) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.interp.Define(clauseText)
}

func (e *MangleEngine) Resolve(query string) (*Resolution, error) {
	e.mu.RLock()
	defer e.mu.RUnlock()

	atom, err := parse.Atom(fmt.Sprintf(`resolve(%q, Answer, Path, Score)`, query))
	if err != nil {
		return nil, fmt.Errorf("failed to parse query atom: %w", err)
	}

	results, err := e.interp.Query(atom)
	if err != nil {
		return nil, fmt.Errorf("mangle evaluation failed: %w", err)
	}

	if len(results) == 0 {
		return &Resolution{Path: "no_match", Confidence: 0}, nil
	}

	// Extract first result
	res := &Resolution{}
	for _, term := range results {
		if a, ok := term.(ast.Atom); ok {
			args := a.Args
			if len(args) >= 4 {
				res.Answer = extractString(args[1])
				res.Path = extractString(args[2])
				res.Confidence = extractFloat(args[3])
			}
		}
	}
	return res, nil
}

func extractString(t ast.BaseTerm) string {
	if c, ok := t.(ast.Constant); ok {
		return c.StringValue()
	}
	return ""
}

func extractFloat(t ast.BaseTerm) float64 {
	if c, ok := t.(ast.Constant); ok {
		if f, err := c.NumberValue(); err == nil {
			return f
		}
	}
	return 0
}
```

**Step 5: Run test to verify it passes**

Run: `cd /Users/user/Documents/sap-oss/mangle-query-service && go test ./internal/engine/ -v`
Expected: PASS (both tests).

Note: The `TestResolveWithMockFacts` test may need adjustments based on how the Mangle interpreter handles query results. Iterate until passing.

**Step 6: Commit**

```bash
cd /Users/user/Documents/sap-oss
git add mangle-query-service/internal/engine/ mangle-query-service/rules/
git commit -m "feat: wire Mangle engine with rule loading and Resolve method"
```

---

### Task 4: Implement gRPC server

**Files:**
- Create: `mangle-query-service/internal/server/grpc.go`
- Create: `mangle-query-service/internal/server/grpc_test.go`
- Modify: `mangle-query-service/cmd/server/main.go`

**Step 1: Write the failing test**

```go
// internal/server/grpc_test.go
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
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/user/Documents/sap-oss/mangle-query-service && go test ./internal/server/ -v`
Expected: FAIL — package does not exist.

**Step 3: Write grpc.go**

```go
// internal/server/grpc.go
package server

import (
	"context"
	"time"

	pb "github.com/sap-oss/mangle-query-service/api/gen"
	"github.com/sap-oss/mangle-query-service/internal/engine"
)

type GRPCServer struct {
	pb.UnimplementedQueryServiceServer
	engine *engine.MangleEngine
}

func NewGRPCServer(rulesDir string) (*GRPCServer, error) {
	eng, err := engine.New(rulesDir)
	if err != nil {
		return nil, err
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
```

**Step 4: Update main.go to start gRPC server**

```go
// cmd/server/main.go
package main

import (
	"fmt"
	"log"
	"net"
	"os"

	"google.golang.org/grpc"

	pb "github.com/sap-oss/mangle-query-service/api/gen"
	"github.com/sap-oss/mangle-query-service/internal/config"
	"github.com/sap-oss/mangle-query-service/internal/server"
)

func main() {
	cfgPath := os.Getenv("MQS_CONFIG")
	var cfg *config.Config
	if cfgPath != "" {
		var err error
		cfg, err = config.Load(cfgPath)
		if err != nil {
			log.Fatalf("failed to load config: %v", err)
		}
	} else {
		cfg = config.Default()
	}

	srv, err := server.NewGRPCServer(cfg.RulesDir)
	if err != nil {
		log.Fatalf("failed to create server: %v", err)
	}

	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", cfg.GRPCPort))
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	grpcServer := grpc.NewServer()
	pb.RegisterQueryServiceServer(grpcServer, srv)

	log.Printf("Mangle Query Service listening on gRPC port %d", cfg.GRPCPort)
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
```

**Step 5: Run test to verify it passes**

Run: `cd /Users/user/Documents/sap-oss/mangle-query-service && go test ./internal/server/ -v`
Expected: PASS.

**Step 6: Commit**

```bash
cd /Users/user/Documents/sap-oss
git add mangle-query-service/internal/server/ mangle-query-service/cmd/server/main.go
git commit -m "feat: implement gRPC server with Resolve and Health RPCs"
```

---

### Task 5: Verify end-to-end server starts

**Step 1: Build and run**

```bash
cd /Users/user/Documents/sap-oss/mangle-query-service
go build -o bin/mqs ./cmd/server/
./bin/mqs
```

Expected: `Mangle Query Service listening on gRPC port 50051`

**Step 2: Test with grpcurl (if available)**

```bash
grpcurl -plaintext localhost:50051 mqs.v1.QueryService/Health
```

Expected: `{ "status": "healthy" }`

**Step 3: Commit**

```bash
cd /Users/user/Documents/sap-oss
git add mangle-query-service/
git commit -m "feat: verify end-to-end server startup"
```

---

## Phase B: Elasticsearch Predicates

### Task 6: Add Elasticsearch client and index management

**Files:**
- Create: `mangle-query-service/internal/es/client.go`
- Create: `mangle-query-service/internal/es/indices.go`
- Create: `mangle-query-service/internal/es/client_test.go`

**Step 1: Add ES dependency**

```bash
cd /Users/user/Documents/sap-oss/mangle-query-service
go get github.com/elastic/go-elasticsearch/v8
```

**Step 2: Write the failing test**

```go
// internal/es/client_test.go
package es

import (
	"testing"
)

func TestNewClient(t *testing.T) {
	// This test verifies client creation with default config
	client, err := NewClient("http://localhost:9200")
	if err != nil {
		t.Fatalf("failed to create client: %v", err)
	}
	if client == nil {
		t.Fatal("client is nil")
	}
}
```

**Step 3: Write client.go**

```go
// internal/es/client.go
package es

import (
	"fmt"

	"github.com/elastic/go-elasticsearch/v8"
)

type Client struct {
	es *elasticsearch.Client
}

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

func (c *Client) Raw() *elasticsearch.Client {
	return c.es
}
```

**Step 4: Write indices.go with index creation logic**

```go
// internal/es/indices.go
package es

import (
	"context"
	"fmt"
	"strings"
)

const CacheQAMapping = `{
	"mappings": {
		"properties": {
			"query_text":      {"type": "text"},
			"query_embedding": {"type": "dense_vector", "dims": 1536, "similarity": "cosine"},
			"answer_text":     {"type": "text"},
			"source_path":     {"type": "keyword"},
			"generated_by":    {"type": "keyword"},
			"created_at":      {"type": "date"},
			"hit_count":       {"type": "integer"},
			"ttl_expires":     {"type": "date"}
		}
	}
}`

const DocumentsMapping = `{
	"mappings": {
		"properties": {
			"title":             {"type": "text"},
			"content":           {"type": "text"},
			"content_embedding": {"type": "dense_vector", "dims": 1536, "similarity": "cosine"},
			"source":            {"type": "keyword"},
			"category":          {"type": "keyword"},
			"chunk_index":       {"type": "integer"},
			"parent_doc_id":     {"type": "keyword"},
			"hana_table":        {"type": "keyword"},
			"last_synced_at":    {"type": "date"}
		}
	}
}`

func BusinessEntityMapping(entityType string) string {
	return fmt.Sprintf(`{
		"mappings": {
			"properties": {
				"hana_key":        {"type": "keyword"},
				"entity_type":     {"type": "keyword"},
				"fields":          {"type": "object", "dynamic": true},
				"display_text":    {"type": "text"},
				"last_synced_at":  {"type": "date"},
				"hana_changed_at": {"type": "date"}
			}
		}
	}`)
}

func (c *Client) EnsureIndex(ctx context.Context, name string, mapping string) error {
	res, err := c.es.Indices.Exists([]string{name})
	if err != nil {
		return fmt.Errorf("failed to check index %s: %w", name, err)
	}
	defer res.Body.Close()

	if res.StatusCode == 200 {
		return nil // already exists
	}

	res, err = c.es.Indices.Create(name, c.es.Indices.Create.WithBody(strings.NewReader(mapping)))
	if err != nil {
		return fmt.Errorf("failed to create index %s: %w", name, err)
	}
	defer res.Body.Close()

	if res.IsError() {
		return fmt.Errorf("error creating index %s: %s", name, res.String())
	}
	return nil
}
```

**Step 5: Run test**

Run: `cd /Users/user/Documents/sap-oss/mangle-query-service && go test ./internal/es/ -v -run TestNewClient`
Expected: PASS (client creation doesn't need a running ES).

**Step 6: Commit**

```bash
cd /Users/user/Documents/sap-oss
git add mangle-query-service/internal/es/
git commit -m "feat: add Elasticsearch client and index mappings"
```

---

### Task 7: Implement ES cache predicate

**Files:**
- Create: `mangle-query-service/internal/predicates/es_cache.go`
- Create: `mangle-query-service/internal/predicates/es_cache_test.go`

**Step 1: Write the failing test**

```go
// internal/predicates/es_cache_test.go
package predicates

import (
	"testing"

	"github.com/google/mangle/ast"
)

func TestESCachePredicate_ShouldPushdown(t *testing.T) {
	p := &ESCachePredicate{}
	if p.ShouldPushdown() != false {
		t.Error("expected ShouldPushdown to return false")
	}
}

func TestESCachePredicate_ShouldQuery(t *testing.T) {
	p := &ESCachePredicate{}
	inputs := []ast.Constant{ast.String("test query")}
	if !p.ShouldQuery(inputs, nil, nil) {
		t.Error("expected ShouldQuery to return true for non-empty query")
	}
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/user/Documents/sap-oss/mangle-query-service && go test ./internal/predicates/ -v`
Expected: FAIL — package does not exist.

**Step 3: Write es_cache.go**

```go
// internal/predicates/es_cache.go
package predicates

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"

	"github.com/elastic/go-elasticsearch/v8"
	"github.com/google/mangle/ast"
)

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

	queryText := inputs[0].StringValue()
	index := p.Index
	if index == "" {
		index = "cache-qa"
	}

	// Build kNN search query
	// For now this is a text match — will be replaced with vector search
	// once query embeddings are passed in
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
		cb([]ast.BaseTerm{
			ast.String(hit.Source.AnswerText),
			ast.Float64(hit.Score),
		})
	}

	return nil
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/user/Documents/sap-oss/mangle-query-service && go test ./internal/predicates/ -v`
Expected: PASS.

**Step 5: Commit**

```bash
cd /Users/user/Documents/sap-oss
git add mangle-query-service/internal/predicates/
git commit -m "feat: implement ES cache lookup predicate for Mangle"
```

---

### Task 8: Implement ES hybrid search predicate

**Files:**
- Create: `mangle-query-service/internal/predicates/es_hybrid.go`
- Create: `mangle-query-service/internal/predicates/es_hybrid_test.go`

**Step 1: Write the failing test**

```go
// internal/predicates/es_hybrid_test.go
package predicates

import (
	"testing"

	"github.com/google/mangle/ast"
)

func TestESHybridPredicate_ShouldQuery(t *testing.T) {
	p := &ESHybridPredicate{}
	inputs := []ast.Constant{ast.String("how to configure SSO")}
	if !p.ShouldQuery(inputs, nil, nil) {
		t.Error("expected ShouldQuery to return true")
	}
}

func TestESHybridPredicate_ShouldQueryEmpty(t *testing.T) {
	p := &ESHybridPredicate{}
	if p.ShouldQuery(nil, nil, nil) {
		t.Error("expected ShouldQuery to return false for empty inputs")
	}
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/user/Documents/sap-oss/mangle-query-service && go test ./internal/predicates/ -v -run TestESHybrid`
Expected: FAIL — type not found.

**Step 3: Write es_hybrid.go**

```go
// internal/predicates/es_hybrid.go
package predicates

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"

	"github.com/elastic/go-elasticsearch/v8"
	"github.com/google/mangle/ast"
)

type ESHybridPredicate struct {
	ES           *elasticsearch.Client
	Index        string  // default: "documents"
	KNNWeight    float64 // default: 0.7
	BM25Weight   float64 // default: 0.3
	TopK         int     // default: 5
}

func (p *ESHybridPredicate) ShouldPushdown() bool { return false }

func (p *ESHybridPredicate) ShouldQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term) bool {
	return len(inputs) > 0
}

func (p *ESHybridPredicate) ExecuteQuery(inputs []ast.Constant, filters []ast.BaseTerm, pushdown []ast.Term, cb func([]ast.BaseTerm)) error {
	if len(inputs) == 0 {
		return fmt.Errorf("es_hybrid_search requires at least 1 input (query text)")
	}

	queryText := inputs[0].StringValue()
	index := p.Index
	if index == "" {
		index = "documents"
	}
	topK := p.TopK
	if topK == 0 {
		topK = 5
	}

	// Hybrid query: BM25 text match + kNN vector search
	// The kNN part will be added once embeddings are passed as input[1]
	query := map[string]interface{}{
		"query": map[string]interface{}{
			"match": map[string]interface{}{
				"content": queryText,
			},
		},
		"size": topK,
	}

	// If embedding vector is provided as second input, add kNN
	// This will be wired up when cap-llm-plugin passes pre-computed embeddings
	// For now, BM25-only search

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

	// Return serialized JSON array of documents + top score
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
	cb([]ast.BaseTerm{
		ast.String(string(docsJSON)),
		ast.Float64(topScore),
	})

	return nil
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/user/Documents/sap-oss/mangle-query-service && go test ./internal/predicates/ -v -run TestESHybrid`
Expected: PASS.

**Step 5: Commit**

```bash
cd /Users/user/Documents/sap-oss
git add mangle-query-service/internal/predicates/es_hybrid.go mangle-query-service/internal/predicates/es_hybrid_test.go
git commit -m "feat: implement ES hybrid search predicate (BM25 + kNN)"
```

---

### Task 9: Implement ES business search predicate

**Files:**
- Create: `mangle-query-service/internal/predicates/es_business.go`
- Create: `mangle-query-service/internal/predicates/es_business_test.go`

Follow same pattern as Tasks 7-8. The predicate queries `business-{entityType}` index by `hana_key` or full-text search on `display_text`. Returns `display_text` and score.

**Step 1: Write failing test, Step 2: verify fails, Step 3: implement, Step 4: verify passes, Step 5: commit.**

```bash
git commit -m "feat: implement ES business entity search predicate"
```

---

### Task 10: Register all ES predicates in engine

**Files:**
- Modify: `mangle-query-service/internal/engine/engine.go`
- Modify: `mangle-query-service/internal/server/grpc.go`

Wire ES predicates into the Mangle engine via `WithExternalPredicates`. Update `NewGRPCServer` to accept an ES client and pass it through.

**Step 1: Write failing test, Step 2: verify fails, Step 3: implement, Step 4: verify passes, Step 5: commit.**

```bash
git commit -m "feat: register ES predicates as Mangle external callbacks"
```

---

## Phase C: Routing Rules

### Task 11: Write classification rules

**Files:**
- Create: `mangle-query-service/rules/routing.mg`
- Create: `mangle-query-service/internal/engine/routing_test.go`

**Step 1: Write the failing test**

```go
// internal/engine/routing_test.go
package engine

import (
	"testing"
)

func TestClassifyCached(t *testing.T) {
	eng := newTestEngine(t)
	eng.DefineFact(`es_cache_lookup("return policy", "30-day returns", 0.97).`)

	result, _ := eng.Resolve("return policy")
	assertEqual(t, result.Path, "cache")
}

func TestClassifyFactual(t *testing.T) {
	eng := newTestEngine(t)
	eng.DefineFact(`classify_query("show me order PO-123", "FACTUAL", 0.92).`)
	eng.DefineFact(`extract_entities("show me order PO-123", "orders", "PO-123").`)
	eng.DefineFact(`es_search("orders", "PO-123", "Order PO-123: delivered", 0.99).`)

	result, _ := eng.Resolve("show me order PO-123")
	assertEqual(t, result.Path, "factual")
}

func TestClassifyRAG(t *testing.T) {
	eng := newTestEngine(t)
	eng.DefineFact(`classify_query("how to configure SSO", "RAG_RETRIEVAL", 0.85).`)
	eng.DefineFact(`es_hybrid_search("how to configure SSO", "[{\"content\":\"SSO setup guide...\"}]", 0.82).`)
	eng.DefineFact(`rerank("how to configure SSO", "[{\"content\":\"SSO setup guide...\"}]", "[{\"content\":\"SSO setup guide...\"}]").`)

	result, _ := eng.Resolve("how to configure SSO")
	assertEqual(t, result.Path, "rag")
}

func TestClassifyLLMRequired(t *testing.T) {
	eng := newTestEngine(t)
	eng.DefineFact(`classify_query("why did sales drop in Q3", "LLM_REQUIRED", 0.88).`)
	eng.DefineFact(`es_hybrid_search("why did sales drop in Q3", "[{\"content\":\"Q3 report\"}]", 0.7).`)
	eng.DefineFact(`llm_generate("why did sales drop in Q3", "[{\"content\":\"Q3 report\"}]", "Sales dropped because...").`)

	result, _ := eng.Resolve("why did sales drop in Q3")
	assertEqual(t, result.Path, "llm")
}

func TestFallbackToLLM(t *testing.T) {
	eng := newTestEngine(t)
	// No classification, no cache — should fall through to LLM
	eng.DefineFact(`es_hybrid_search("something weird", "[]", 0.3).`)
	eng.DefineFact(`llm_generate("something weird", "[]", "I can help with that...").`)

	result, _ := eng.Resolve("something weird")
	assertEqual(t, result.Path, "llm")
}

func newTestEngine(t *testing.T) *MangleEngine {
	t.Helper()
	eng, err := New("../../rules/")
	if err != nil {
		t.Fatalf("failed to create engine: %v", err)
	}
	return eng
}

func assertEqual(t *testing.T, got, want string) {
	t.Helper()
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}
```

**Step 2: Write routing.mg with full classification rules**

```prolog
# rules/routing.mg

# === Query Classification ===

is_cached(Query) :-
    es_cache_lookup(Query, _Answer, Score),
    Score >= 0.95.

is_factual(Query) :-
    classify_query(Query, "FACTUAL", Confidence),
    Confidence >= 0.7,
    extract_entities(Query, _EntityType, _EntityId).

is_knowledge(Query) :-
    classify_query(Query, "RAG_RETRIEVAL", Confidence),
    Confidence >= 0.7.

llm_required(Query) :-
    classify_query(Query, "LLM_REQUIRED", _Confidence).
```

**Step 3: Run tests, iterate until all 5 pass.**

**Step 4: Commit**

```bash
git commit -m "feat: write Mangle routing rules with 5 classification tests"
```

---

### Task 12: Write resolution rules

**Files:**
- Create: `mangle-query-service/rules/resolution.mg`

Full resolution rules for all 4 paths + cache population after LLM generation. Test with mock facts.

```bash
git commit -m "feat: write Mangle resolution rules for all 4 paths"
```

---

### Task 13: Write caching and freshness rules

**Files:**
- Create: `mangle-query-service/rules/caching.mg`
- Create: `mangle-query-service/rules/freshness.mg`

Cache invalidation rules, TTL-based staleness, sync overdue detection, sync drift alerts. Test with temporal mock facts.

```bash
git commit -m "feat: write Mangle caching and freshness rules"
```

---

### Task 14: Write error handling and fallback rules

**Files:**
- Create: `mangle-query-service/rules/error_handling.mg`

Degradation cascade rules, circuit breaker state facts, fallback paths. Test every degradation scenario.

```bash
git commit -m "feat: write Mangle error handling and fallback rules"
```

---

## Phase D: hana_ai MCP Integration

### Task 15: Adapt Mem0IngestionClassifier for query routing

**Files:**
- Create: `hana-ai-mcp-server/query_classifier.py`
- Create: `hana-ai-mcp-server/query_classifier_test.py`

**Step 1: Write the failing test**

```python
# query_classifier_test.py
from query_classifier import QueryClassifier

def test_classify_factual():
    classifier = QueryClassifier(llm=mock_llm)
    result = classifier.classify("Show me order PO-12345")
    assert result["category"] in ["CACHED", "FACTUAL", "RAG_RETRIEVAL", "LLM_REQUIRED"]
    assert 0 <= result["confidence"] <= 1

def test_classify_llm_required():
    classifier = QueryClassifier(llm=mock_llm)
    result = classifier.classify("Why did sales drop compared to last quarter?")
    assert result["category"] == "LLM_REQUIRED"
```

**Step 2: Implement QueryClassifier extending Mem0IngestionClassifier**

Adapt the prompt template to classify into our 4 categories instead of the original 5 memory categories. Keep bilingual support and confidence scoring.

**Step 3: Run tests, Step 4: Commit**

```bash
git commit -m "feat: adapt Mem0IngestionClassifier for query routing classification"
```

---

### Task 16: Create hana_ai MCP server with query tools

**Files:**
- Create: `hana-ai-mcp-server/server.py`
- Create: `hana-ai-mcp-server/requirements.txt`

Register adapted classifier, entity extractor, cross-encoder reranker, and RAGAgent as MCP tools via `HANAMLToolkit.launch_mcp_server()`.

```bash
git commit -m "feat: create hana_ai MCP server exposing classifier, extractor, reranker"
```

---

### Task 17: Implement Go MCP client predicates

**Files:**
- Create: `mangle-query-service/internal/predicates/mcp_classify.go`
- Create: `mangle-query-service/internal/predicates/mcp_entities.go`
- Create: `mangle-query-service/internal/predicates/mcp_rerank.go`
- Create: `mangle-query-service/internal/predicates/mcp_llm.go`

Each predicate calls the hana_ai MCP server via HTTP and translates results into Mangle facts. Follow same test pattern as ES predicates.

```bash
git commit -m "feat: implement Go MCP client predicates for hana_ai tools"
```

---

### Task 18: Register MCP predicates in engine

**Files:**
- Modify: `mangle-query-service/internal/engine/engine.go`

Wire classify_query, extract_entities, rerank, llm_generate predicates to MCP client. Test with mock MCP server.

```bash
git commit -m "feat: register MCP predicates in Mangle engine"
```

---

## Phase E: HANA Sync Pipeline

### Task 19: Implement batch ETL

**Files:**
- Create: `mangle-query-service/internal/sync/batch_etl.go`
- Create: `mangle-query-service/internal/sync/batch_etl_test.go`

Scheduled goroutine that reads HANA changes since last sync, chunks documents, generates embeddings via MCP, bulk-indexes into ES.

```bash
git commit -m "feat: implement batch ETL pipeline for HANA -> ES sync"
```

---

### Task 20: Implement CDC listener

**Files:**
- Create: `mangle-query-service/internal/sync/cdc_listener.go`

Receives SyncEntity gRPC calls from cap-llm-plugin, indexes into ES, invalidates cache via Mangle rules.

```bash
git commit -m "feat: implement CDC listener for real-time HANA -> ES sync"
```

---

### Task 21: Implement cache invalidation

**Files:**
- Modify: `mangle-query-service/internal/predicates/es_cache.go`

Add `ESCacheStorePredicate` (writes Q&A pairs) and `ESCacheInvalidatePredicate` (evicts by entity reference).

```bash
git commit -m "feat: implement ES cache store and invalidation predicates"
```

---

### Task 22: Wire sync into server startup

**Files:**
- Modify: `mangle-query-service/cmd/server/main.go`

Start batch ETL goroutine on server boot. Configure sync modes from Mangle facts.

```bash
git commit -m "feat: wire sync pipelines into server startup"
```

---

## Phase F: cap-llm-plugin Integration

### Task 23: Add gRPC client to cap-llm-plugin

**Files:**
- Create: `cap-llm-plugin-main/src/mangle-client.ts`
- Create: `cap-llm-plugin-main/tests/unit/mangle-client.test.js`

**Step 1: Install gRPC dependencies**

```bash
cd /Users/user/Documents/sap-oss/cap-llm-plugin-main
npm install @grpc/grpc-js @grpc/proto-loader
```

**Step 2: Write the failing test**

```javascript
// tests/unit/mangle-client.test.js
const { MangleClient } = require('../../src/mangle-client');

describe('MangleClient', () => {
  test('creates client with default config', () => {
    const client = new MangleClient({ address: 'localhost:50051' });
    expect(client).toBeDefined();
  });

  test('resolve returns structured response', async () => {
    const client = new MangleClient({ address: 'localhost:50051' });
    // Mock the gRPC call
    client._client = { Resolve: (req, cb) => cb(null, {
      answer: 'test answer',
      path: 'cache',
      confidence: 0.97,
      sources: [],
      latencyMs: 12,
      correlationId: 'test-123'
    })};

    const result = await client.resolve('test query', [], 'test-123');
    expect(result.path).toBe('cache');
    expect(result.answer).toBe('test answer');
  });
});
```

**Step 3: Implement MangleClient**

```typescript
// src/mangle-client.ts
import * as grpc from '@grpc/grpc-js';
import * as protoLoader from '@grpc/proto-loader';
import * as path from 'path';

export interface MangleConfig {
  address: string;
  timeout?: number;
}

export interface MangleResponse {
  answer: string;
  path: 'cache' | 'factual' | 'rag' | 'llm' | 'llm_fallback' | 'no_match';
  confidence: number;
  sources: Array<{ title: string; content: string; origin: string; score: number }>;
  latencyMs: number;
  correlationId: string;
}

export class MangleClient {
  _client: any;

  constructor(config: MangleConfig) {
    const PROTO_PATH = path.resolve(__dirname, '../proto/query.proto');
    const packageDefinition = protoLoader.loadSync(PROTO_PATH, {
      keepCase: false,
      longs: String,
      enums: String,
      defaults: true,
      oneofs: true,
    });
    const proto = grpc.loadPackageDefinition(packageDefinition) as any;
    this._client = new proto.mqs.v1.QueryService(
      config.address,
      grpc.credentials.createInsecure()
    );
  }

  async resolve(query: string, queryEmbedding: number[], correlationId: string): Promise<MangleResponse> {
    return new Promise((resolve, reject) => {
      this._client.Resolve(
        { query, queryEmbedding, correlationId },
        { deadline: new Date(Date.now() + 10000) },
        (err: Error | null, response: MangleResponse) => {
          if (err) reject(err);
          else resolve(response);
        }
      );
    });
  }
}
```

**Step 4: Run test, Step 5: Commit**

```bash
git commit -m "feat: add Mangle gRPC client to cap-llm-plugin"
```

---

### Task 24: Add resolveQuery method to CAPLLMPlugin

**Files:**
- Modify: `cap-llm-plugin-main/srv/cap-llm-plugin.ts`
- Create: `cap-llm-plugin-main/tests/unit/resolve-query.test.js`

Add `resolveQuery(query: string): Promise<MangleResponse>` that:
1. Generates query embedding via `OrchestrationEmbeddingClient`
2. Calls `mangleClient.resolve(query, embedding, correlationId)`
3. Returns structured response

```bash
git commit -m "feat: add resolveQuery method using Mangle service"
```

---

### Task 25: Add CDS @after hooks for CDC

**Files:**
- Modify: `cap-llm-plugin-main/cds-plugin.ts`

Add `@after('CREATE', 'UPDATE', 'DELETE')` hooks that call `mangleClient.syncEntity()` for real-time CDC.

```bash
git commit -m "feat: add CDS event hooks for real-time CDC to Mangle service"
```

---

## Phase G: Observability + Resilience

### Task 26: Add circuit breakers to all predicates

**Files:**
- Create: `mangle-query-service/internal/resilience/circuit_breaker.go`
- Create: `mangle-query-service/internal/resilience/circuit_breaker_test.go`

Wrap each external predicate's `ExecuteQuery` with a circuit breaker. Expose state as Mangle facts.

```bash
git commit -m "feat: add circuit breakers to all external predicates"
```

---

### Task 27: Add Prometheus metrics

**Files:**
- Create: `mangle-query-service/internal/metrics/metrics.go`
- Modify: `mangle-query-service/cmd/server/main.go`

Counters: `query_total`, `fallback_total`. Histograms: `query_latency_seconds`, `es_search_latency_seconds`. Gauges: `cache_hit_ratio`, `resolution_path_ratio`, `sync_lag_seconds`.

```bash
git commit -m "feat: add Prometheus metrics for all resolution paths"
```

---

### Task 28: Add OpenTelemetry trace propagation

**Files:**
- Create: `mangle-query-service/internal/tracing/tracing.go`

Propagate `correlation_id` as OTel trace context from gRPC metadata through to ES/MCP calls.

```bash
git commit -m "feat: add OpenTelemetry trace propagation"
```

---

## Phase H: Integration + E2E Tests

### Task 29: Mangle + ES integration tests

**Files:**
- Create: `mangle-query-service/tests/integration/es_test.go`

Use testcontainers to spin up real ES. Test: cache round-trip, hybrid search quality, index creation.

```bash
git commit -m "test: add Mangle + Elasticsearch integration tests"
```

---

### Task 30: 80/20 validation test

**Files:**
- Create: `mangle-query-service/tests/integration/distribution_test.go`
- Create: `mangle-query-service/tests/testdata/representative_queries.json`

Run 100 representative queries. Assert >= 75% resolve without LLM.

```bash
git commit -m "test: add 80/20 resolution path distribution validation"
```

---

### Task 31: E2E smoke test

**Files:**
- Create: `mangle-query-service/tests/e2e/smoke_test.go`

Start full server, seed ES with test data, run 5 scenarios (cached, factual, rag, llm, degraded mode).

```bash
git commit -m "test: add E2E smoke test for all resolution paths"
```

---

## Deployment Checklist

After all tasks complete:

- [ ] `mangle-query-service` builds and all tests pass
- [ ] `hana-ai-mcp-server` starts and responds to tool calls
- [ ] `cap-llm-plugin` `resolveQuery()` works against local Mangle service
- [ ] ES indices created and populated from test data
- [ ] 80/20 distribution test passes
- [ ] Circuit breakers activate on simulated failures
- [ ] Prometheus metrics endpoint returns valid data
- [ ] Dockerfile builds and runs
