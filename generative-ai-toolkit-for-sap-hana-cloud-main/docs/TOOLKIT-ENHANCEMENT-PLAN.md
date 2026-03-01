# Generative AI Toolkit Enhancement Plan

## Current State Analysis

### Strengths
1. **Comprehensive Toolkit** - 25+ tools for time series, forecasting, ML operations
2. **HANAMLRAGAgent** - Sophisticated RAG with short/long-term memory
3. **MCP Server** - Full MCP implementation with federation support
4. **Vector Engine** - HANAMLinVectorEngine with internal embeddings
5. **Cross-encoder Support** - PALCrossEncoder for reranking

### Integration Opportunities

The toolkit can benefit from the enhancements already built in `mangle-query-service`:
- Semantic caching
- Circuit breaker resilience
- Query rewriting
- Adaptive routing
- Observability

---

## Enhancement Roadmap

### Phase 1: Performance Optimizations (Week 1-2)

#### 1.1 Semantic Query Cache for Vector Engine
**File:** `src/hana_ai/vectorstore/semantic_cache.py`
- Cache vector search results by embedding similarity
- TTL-based expiration
- Expected: 60-80% cache hit rate

#### 1.2 Batch Embedding Support
**File:** `src/hana_ai/vectorstore/batch_embeddings.py`
- Batch multiple texts for embedding generation
- Reduce round trips to HANA
- Expected: 5-10x throughput improvement

#### 1.3 Connection Pooling for RAG Agent
**Enhancement:** `src/hana_ai/agents/hanaml_rag_agent.py`
- Add connection pool management
- Warm up connections on initialization

### Phase 2: Resilience Patterns (Week 2-3)

#### 2.1 Circuit Breaker for Tools
**File:** `src/hana_ai/tools/resilience/circuit_breaker.py`
- Protect against HANA/AI Core failures
- Fallback mechanisms for critical tools
- Integration with HANAMLToolkit

#### 2.2 Retry Handler
**File:** `src/hana_ai/tools/resilience/retry_handler.py`
- Exponential backoff for transient failures
- Configurable retry policies per tool

#### 2.3 Health Monitoring
**File:** `src/hana_ai/monitoring/health_checker.py`
- Periodic health checks for HANA and AI Core
- Alert on degradation

### Phase 3: Intelligence Enhancements (Week 3-4)

#### 3.1 Query Rewriting for RAG
**Enhancement:** `src/hana_ai/agents/query_rewriter.py`
- HyDE (Hypothetical Document Embeddings)
- Query expansion
- Multi-query retrieval

#### 3.2 Adaptive Tool Selection
**File:** `src/hana_ai/tools/adaptive_selector.py`
- Learn which tools work best for query types
- Thompson sampling / UCB algorithm

#### 3.3 Enhanced Reranking
**Enhancement:** `src/hana_ai/vectorstore/enhanced_reranker.py`
- Diversity-based reranking (MMR)
- Recency boosting
- Entity-aware reranking

### Phase 4: Observability (Week 4-5)

#### 4.1 OpenTelemetry Integration
**File:** `src/hana_ai/observability/tracing.py`
- Distributed tracing for all tool calls
- Span context propagation

#### 4.2 Metrics Collection
**File:** `src/hana_ai/observability/metrics.py`
- Prometheus metrics for:
  - Tool invocations
  - Cache performance
  - Agent iterations
  - Memory usage

### Phase 5: MCP Server Enhancements (Week 5-6)

#### 5.1 Rate Limiting
**Enhancement:** `mcp_server/server.py`
- Token bucket rate limiting
- Per-client limits

#### 5.2 Enhanced Federation
**Enhancement:** `mcp_server/server.py`
- Smarter routing to federated endpoints
- Health-aware endpoint selection

---

## Detailed Implementation

### 1. Semantic Cache for Vector Engine

```python
# src/hana_ai/vectorstore/semantic_cache.py

class HANASemanticCache:
    """
    Semantic cache for HANA vector search results.
    
    Caches results by embedding similarity rather than exact query match.
    """
    
    def __init__(
        self,
        connection_context: ConnectionContext = None,
        max_size: int = 10000,
        ttl_seconds: int = 3600,
        similarity_threshold: float = 0.92,
    ):
        self.connection_context = connection_context
        self.max_size = max_size
        self.ttl_seconds = ttl_seconds
        self.similarity_threshold = similarity_threshold
        self._cache = {}
        self._embeddings = {}
        
    async def get(
        self,
        query: str,
        query_embedding: List[float],
    ) -> Tuple[Optional[Any], float]:
        """Get cached result if similar query exists."""
        best_match = None
        best_similarity = 0.0
        
        for key, cached in self._cache.items():
            if self._is_expired(cached):
                continue
                
            cached_embedding = self._embeddings.get(key)
            if cached_embedding is None:
                continue
                
            similarity = self._cosine_similarity(query_embedding, cached_embedding)
            
            if similarity > best_similarity and similarity >= self.similarity_threshold:
                best_similarity = similarity
                best_match = cached["result"]
        
        return best_match, best_similarity
    
    async def set(
        self,
        query: str,
        query_embedding: List[float],
        result: Any,
    ) -> None:
        """Cache a result."""
        # LRU eviction
        if len(self._cache) >= self.max_size:
            self._evict_oldest()
        
        cache_key = self._hash_embedding(query_embedding)
        self._cache[cache_key] = {
            "result": result,
            "timestamp": time.time(),
            "query": query,
        }
        self._embeddings[cache_key] = query_embedding
```

### 2. Circuit Breaker for Tools

```python
# src/hana_ai/tools/resilience/circuit_breaker.py

class ToolCircuitBreaker:
    """Circuit breaker for HANA AI tools."""
    
    def __init__(
        self,
        failure_threshold: int = 5,
        recovery_timeout: float = 30.0,
    ):
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout
        self._state = CircuitState.CLOSED
        self._failure_count = 0
        self._last_failure_time = None
    
    async def execute(
        self,
        tool: BaseTool,
        *args,
        fallback: Optional[Callable] = None,
        **kwargs,
    ) -> Any:
        """Execute tool with circuit breaker protection."""
        if self._state == CircuitState.OPEN:
            if self._should_attempt_recovery():
                self._state = CircuitState.HALF_OPEN
            elif fallback:
                return await fallback(*args, **kwargs)
            else:
                raise CircuitOpenError(f"Circuit breaker open for {tool.name}")
        
        try:
            result = await tool._arun(*args, **kwargs)
            self._record_success()
            return result
        except Exception as e:
            self._record_failure()
            if fallback:
                return await fallback(*args, **kwargs)
            raise
```

### 3. Enhanced RAG Agent Memory

```python
# Enhancement to src/hana_ai/agents/hanaml_rag_agent.py

class EnhancedHANAMLRAGAgent(HANAMLRAGAgent):
    """Enhanced RAG agent with semantic caching and query rewriting."""
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        
        # Add semantic cache
        self.query_cache = HANASemanticCache(
            connection_context=self.hana_connection_context,
            similarity_threshold=0.92,
        )
        
        # Add query rewriter
        self.query_rewriter = QueryRewriter()
        
        # Add circuit breaker
        self.circuit_breaker = ToolCircuitBreaker()
    
    async def chat(self, user_input: str) -> str:
        """Enhanced chat with caching and rewriting."""
        # 1. Check cache
        embedding = await self._get_embedding(user_input)
        cached_result, similarity = await self.query_cache.get(user_input, embedding)
        
        if cached_result:
            return cached_result
        
        # 2. Rewrite query
        rewritten = await self.query_rewriter.rewrite(user_input)
        
        # 3. Execute with circuit breaker
        result = await self.circuit_breaker.execute(
            super().chat,
            rewritten.rewritten,
        )
        
        # 4. Cache result
        await self.query_cache.set(user_input, embedding, result)
        
        return result
```

### 4. Observability Integration

```python
# src/hana_ai/observability/tracing.py

from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode

class HANAToolTracer:
    """OpenTelemetry tracing for HANA AI tools."""
    
    def __init__(self, service_name: str = "hana-ai-toolkit"):
        self.tracer = trace.get_tracer(service_name)
    
    def trace_tool(self, tool_name: str):
        """Decorator to trace tool execution."""
        def decorator(func):
            async def wrapper(*args, **kwargs):
                with self.tracer.start_as_current_span(
                    f"tool.{tool_name}",
                    attributes={
                        "tool.name": tool_name,
                        "tool.args": str(kwargs)[:1000],
                    }
                ) as span:
                    try:
                        result = await func(*args, **kwargs)
                        span.set_status(Status(StatusCode.OK))
                        return result
                    except Exception as e:
                        span.set_status(Status(StatusCode.ERROR, str(e)))
                        span.record_exception(e)
                        raise
            return wrapper
        return decorator
```

---

## Integration with mangle-query-service

The toolkit can integrate with the already-built mangle-query-service components:

### Shared Components

| mangle-query-service | gen-ai-toolkit | Integration |
|---------------------|----------------|-------------|
| `hana_semantic_cache.py` | New `semantic_cache.py` | Port to toolkit |
| `hana_circuit_breaker.py` | New `circuit_breaker.py` | Port to toolkit |
| `query_rewriter.py` | RAG agent enhancement | Direct import |
| `reranker.py` | Enhanced reranking | Direct import |
| `hana_metrics.py` | New `metrics.py` | Port to toolkit |
| `hana_tracing.py` | New `tracing.py` | Port to toolkit |

### Configuration Alignment

```yaml
# Shared environment variables
HANA_HOST: your-host.hanacloud.ondemand.com
HANA_USER: your-user
HANA_PASSWORD: your-password

# Cache settings (shared)
HANA_CACHE_MAX_SIZE: 10000
HANA_CACHE_TTL_SECONDS: 3600
SEMANTIC_SIMILARITY_THRESHOLD: 0.92

# Circuit breaker (shared)
HANA_CB_FAILURE_THRESHOLD: 5
HANA_CB_RECOVERY_TIMEOUT: 30.0

# Observability (shared)
OTEL_ENABLED: true
OTEL_EXPORTER_OTLP_ENDPOINT: http://localhost:4317
METRICS_ENABLED: true
```

---

## Priority Order

1. **High Priority** (Week 1-2)
   - Semantic cache for vector engine
   - Circuit breaker for tools
   - Batch embeddings

2. **Medium Priority** (Week 3-4)
   - Query rewriting for RAG
   - OpenTelemetry integration
   - Health monitoring

3. **Lower Priority** (Week 5-6)
   - Adaptive tool selection
   - Enhanced MCP federation
   - Advanced reranking strategies

---

## Expected Impact

| Enhancement | Metric | Expected Improvement |
|-------------|--------|---------------------|
| Semantic Cache | Cache hit rate | 60-80% |
| Batch Embeddings | Throughput | 5-10x |
| Circuit Breaker | Availability | 99% → 99.9% |
| Query Rewriting | Retrieval quality | +15-25% |
| Enhanced Reranking | Precision | +10-15% |
| Connection Warmup | Cold start | -90% |

---

## Next Steps

1. Review this plan with stakeholders
2. Create feature branches for each enhancement
3. Implement Phase 1 components
4. Add comprehensive tests
5. Deploy to staging environment
6. Monitor metrics and iterate