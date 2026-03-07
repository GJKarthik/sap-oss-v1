"""
OpenAI-compatible HTTP API for Mangle Query Service.

Provides /v1/chat/completions endpoint that routes queries through Mangle rules.
Integrates with:
- routing.mg: Core query classification and resolution
- analytics_routing.mg: HANA analytics, dimensions, measures, GDPR
"""

from fastapi import FastAPI, HTTPException, Request, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from typing import Optional, List, Dict, Any, Literal
import httpx
import json
import re
import asyncio
import os
from datetime import datetime
from enum import Enum

from .metadata_loader import metadata_loader
from .streaming import create_stream_response_generator

# Import connectors with graceful fallback
try:
    from connectors import hana_resolver, hybrid_search
    CONNECTORS_AVAILABLE = True
except ImportError:
    CONNECTORS_AVAILABLE = False
    hana_resolver = None
    hybrid_search = None

# Import efficiency modules (Phase 1)
try:
    from efficiency.semantic_cache import semantic_cache
    from efficiency.batch_client import get_batched_client, shutdown_batched_client
    EFFICIENCY_AVAILABLE = True
except ImportError:
    EFFICIENCY_AVAILABLE = False
    semantic_cache = None
    get_batched_client = None
    shutdown_batched_client = None

# Feature flags for Phase 1
ENABLE_SEMANTIC_CACHE = os.getenv("ENABLE_SEMANTIC_CACHE", "true").lower() == "true"
ENABLE_REQUEST_BATCHING = os.getenv("ENABLE_REQUEST_BATCHING", "true").lower() == "true"

# Import intelligence modules (Phase 2)
try:
    from intelligence.semantic_classifier import get_classifier
    from intelligence.speculative import get_speculative_executor
    from intelligence.model_selector import get_model_selector
    INTELLIGENCE_AVAILABLE = True
except ImportError:
    INTELLIGENCE_AVAILABLE = False
    get_classifier = None
    get_speculative_executor = None
    get_model_selector = None

# Feature flags for Phase 2
ENABLE_SEMANTIC_CLASSIFIER = os.getenv("ENABLE_SEMANTIC_CLASSIFIER", "true").lower() == "true"
ENABLE_SPECULATIVE_EXECUTION = os.getenv("ENABLE_SPECULATIVE_EXECUTION", "true").lower() == "true"
ENABLE_MODEL_SELECTION = os.getenv("ENABLE_MODEL_SELECTION", "true").lower() == "true"
SPECULATIVE_THRESHOLD = int(os.getenv("SPECULATIVE_THRESHOLD", "75"))

app = FastAPI(
    title="Mangle Query Service - OpenAI API",
    description="OpenAI-compatible API with Mangle routing rules",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
AICORE_URL = os.getenv("AICORE_URL", "https://api.ai.core.sap.cloud")
ES_URL = os.getenv("ELASTICSEARCH_URL", "http://elasticsearch:9200")
HANA_HOST = os.getenv("HANA_HOST", "")
HANA_PORT = os.getenv("HANA_PORT", "443")


class QueryCategory(str, Enum):
    CACHE = "cache"
    FACTUAL = "factual"
    ANALYTICAL = "analytical"
    HIERARCHY = "hierarchy"
    TIMESERIES = "timeseries"
    KNOWLEDGE = "knowledge"
    LLM_REQUIRED = "llm_required"
    METADATA = "metadata"


class ResolutionPath(str, Enum):
    CACHE = "cache"
    ES_FACTUAL = "es_factual"
    ES_AGGREGATION = "es_aggregation"
    HANA_ANALYTICAL = "hana_analytical"
    HANA_HIERARCHY = "hana_hierarchy"
    RAG_ENRICHED = "rag_enriched"
    LLM_FALLBACK = "llm_fallback"
    METADATA = "metadata"


# OpenAI-compatible models
class Message(BaseModel):
    role: Literal["system", "user", "assistant", "function", "tool"]
    content: Optional[str] = None
    name: Optional[str] = None
    tool_calls: Optional[List[Dict[str, Any]]] = None
    tool_call_id: Optional[str] = None


class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[Message]
    temperature: Optional[float] = 0.7
    max_tokens: Optional[int] = None
    stream: Optional[bool] = False
    tools: Optional[List[Dict[str, Any]]] = None
    tool_choice: Optional[str] = None
    
    # Mangle-specific extensions
    routing_hints: Optional[Dict[str, Any]] = Field(None, description="Hints for Mangle routing")
    context_sources: Optional[List[str]] = Field(None, description="Data sources for RAG")


class ChatCompletionChoice(BaseModel):
    index: int
    message: Message
    finish_reason: Optional[str] = "stop"


class Usage(BaseModel):
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int


class ChatCompletionResponse(BaseModel):
    id: str
    object: str = "chat.completion"
    created: int
    model: str
    choices: List[ChatCompletionChoice]
    usage: Usage


# =============================================================================
# Entity Metadata - Loaded dynamically from ES via metadata_loader
# Fallback values used when ES is unavailable
# =============================================================================

# The metadata_loader fetches from these ES indices:
# - entity_registry: Core entity definitions
# - entity_dimensions: Dimension mappings
# - entity_measures: Measure definitions with aggregation types
# - entity_hierarchies: Hierarchy configurations
# - entity_gdpr: Personal data field classifications


class MangleRouter:
    """Routes queries based on Mangle rules from routing.mg and analytics_routing.mg."""
    
    def __init__(self):
        self.cache: Dict[str, Any] = {}
        self.hana_available = bool(HANA_HOST)
        self._metadata: Optional[Dict[str, Any]] = None
    
    async def _get_metadata(self) -> Dict[str, Any]:
        """Get entity metadata from dynamic loader."""
        if self._metadata is None:
            self._metadata = await metadata_loader.get_metadata()
        return self._metadata
    
    async def _get_entities(self) -> Dict[str, Dict[str, str]]:
        """Get analytical entities from metadata."""
        metadata = await self._get_metadata()
        return metadata.get("analytical_entities", {})
    
    async def _get_dimensions(self) -> Dict[str, List[str]]:
        """Get entity dimensions from metadata."""
        metadata = await self._get_metadata()
        return metadata.get("dimensions", {})
    
    async def _get_measures(self) -> Dict[str, Dict[str, str]]:
        """Get entity measures from metadata."""
        metadata = await self._get_metadata()
        return metadata.get("measures", {})
    
    async def _get_hierarchies(self) -> Dict[str, Dict[str, tuple]]:
        """Get entity hierarchies from metadata."""
        metadata = await self._get_metadata()
        return metadata.get("hierarchies", {})
    
    async def _get_personal_data(self) -> Dict[str, Dict[str, str]]:
        """Get GDPR field classifications from metadata."""
        metadata = await self._get_metadata()
        return metadata.get("personal_data", {})
    
    # =========================================================================
    # Query Classification (from routing.mg and analytics_routing.mg)
    # =========================================================================
    
    async def classify_query(self, query: str, hints: Optional[Dict] = None) -> Dict[str, Any]:
        """
        Classify query using Mangle rules:
        - is_cached, is_factual, is_knowledge, is_llm_required (routing.mg)
        - is_analytical_query, is_hierarchy_query, is_timeseries_query (analytics_routing.mg)
        """
        
        classification = {
            "category": QueryCategory.LLM_REQUIRED,
            "route": ResolutionPath.LLM_FALLBACK,
            "requires_rag": True,
            "data_sources": [],
            "entities": [],
            "dimensions": [],
            "measures": [],
            "filters": {},
            "confidence": 50,
            "gdpr_fields": [],
        }
        
        query_lower = query.lower()
        
        # 1. Check cache (highest priority per routing.mg)
        cache_result = await self._check_cache(query)
        if cache_result and cache_result.get("score", 0) >= 95:
            classification["category"] = QueryCategory.CACHE
            classification["route"] = ResolutionPath.CACHE
            classification["confidence"] = cache_result["score"]
            classification["requires_rag"] = False
            return classification
        
        # 2. Extract entities (using dynamic metadata)
        entities = await self._extract_entities(query)
        classification["entities"] = entities
        
        # 3. Check for metadata queries
        if self._is_metadata_query(query):
            classification["category"] = QueryCategory.METADATA
            classification["route"] = ResolutionPath.METADATA
            classification["confidence"] = 95
            classification["requires_rag"] = False
            return classification
        
        # 4. Check for analytical queries (analytics_routing.mg)
        if self._is_analytical_query(query):
            classification["category"] = QueryCategory.ANALYTICAL
            
            # Determine dimensions and measures from dynamic metadata
            entity_dims = await self._get_dimensions()
            entity_measures = await self._get_measures()
            analytical_entities = await self._get_entities()
            
            for entity in entities:
                if entity in entity_dims:
                    classification["dimensions"].extend(entity_dims[entity])
                if entity in entity_measures:
                    classification["measures"].extend(list(entity_measures[entity].keys()))
            
            # Route to HANA or ES
            if self.hana_available and any(e in analytical_entities for e in entities):
                classification["route"] = ResolutionPath.HANA_ANALYTICAL
                classification["confidence"] = 90
            else:
                classification["route"] = ResolutionPath.ES_AGGREGATION
                classification["confidence"] = 70
            
            classification["requires_rag"] = False
            classification["filters"] = self._extract_filters(query)
            
        # 5. Check for hierarchy queries
        elif self._is_hierarchy_query(query):
            classification["category"] = QueryCategory.HIERARCHY
            
            entity_hierarchies = await self._get_hierarchies()
            if self.hana_available and any(e in entity_hierarchies for e in entities):
                classification["route"] = ResolutionPath.HANA_HIERARCHY
                classification["confidence"] = 85
            else:
                classification["route"] = ResolutionPath.RAG_ENRICHED
                classification["confidence"] = 60
        
        # 6. Check for time-series queries
        elif self._is_timeseries_query(query):
            classification["category"] = QueryCategory.TIMESERIES
            
            if self.hana_available:
                classification["route"] = ResolutionPath.HANA_ANALYTICAL
                classification["confidence"] = 85
            else:
                classification["route"] = ResolutionPath.ES_AGGREGATION
                classification["confidence"] = 65
            
            classification["filters"] = self._extract_filters(query)
        
        # 7. Check for factual entity lookup (routing.mg: is_factual)
        elif self._is_factual_query(query) and entities:
            classification["category"] = QueryCategory.FACTUAL
            classification["route"] = ResolutionPath.ES_FACTUAL
            classification["confidence"] = 80
            classification["requires_rag"] = False
        
        # 8. Check for knowledge/RAG queries (routing.mg: is_knowledge)
        elif self._is_knowledge_query(query):
            classification["category"] = QueryCategory.KNOWLEDGE
            classification["route"] = ResolutionPath.RAG_ENRICHED
            classification["confidence"] = 75
            classification["requires_rag"] = True
        
        # 9. Check for GDPR fields (from dynamic metadata)
        personal_data = await self._get_personal_data()
        for entity in entities:
            if entity in personal_data:
                classification["gdpr_fields"].extend([
                    f for f, sens in personal_data[entity].items() 
                    if sens == "sensitive"
                ])
        
        # Override with hints if provided
        if hints:
            if "route" in hints:
                classification["route"] = hints["route"]
            if "requires_rag" in hints:
                classification["requires_rag"] = hints["requires_rag"]
        
        return classification
    
    def _is_analytical_query(self, query: str) -> bool:
        """Check for aggregation keywords (analytics_routing.mg: is_analytical_query)."""
        patterns = [
            r"\b(total|sum|average|avg|count|max|min|aggregate)\b",
            r"\b(trend|compare|growth|percentage|ratio)\b",
            r"\b(by|per|grouped|breakdown|distribution)\b",
        ]
        return any(re.search(p, query, re.IGNORECASE) for p in patterns)
    
    def _is_hierarchy_query(self, query: str) -> bool:
        """Check for hierarchy keywords (analytics_routing.mg: is_hierarchy_query)."""
        pattern = r"\b(hierarchy|drill|expand|collapse|parent|child|level)\b"
        return bool(re.search(pattern, query, re.IGNORECASE))
    
    def _is_timeseries_query(self, query: str) -> bool:
        """Check for time-series keywords (analytics_routing.mg: is_timeseries_query)."""
        time_pattern = r"\b(year|month|quarter|week|daily|monthly|yearly)\b"
        trend_pattern = r"\b(trend|over time|historical|forecast)\b"
        return bool(re.search(time_pattern, query, re.IGNORECASE)) and \
               bool(re.search(trend_pattern, query, re.IGNORECASE))
    
    def _is_factual_query(self, query: str) -> bool:
        """Check for factual lookup patterns (routing.mg: is_factual)."""
        patterns = [
            r"\b(what is|show me|get|lookup|find)\b.+\b(for|of|about)\b",
            r"\b(details|information|data)\b.+\b(for|about)\b",
        ]
        return any(re.search(p, query, re.IGNORECASE) for p in patterns)
    
    def _is_knowledge_query(self, query: str) -> bool:
        """Check for knowledge/RAG patterns (routing.mg: is_knowledge)."""
        patterns = [
            r"\b(explain|describe|how|why|what does)\b",
            r"\b(best practice|recommendation|guidance)\b",
            r"\b(compare|difference|between)\b",
        ]
        return any(re.search(p, query, re.IGNORECASE) for p in patterns)
    
    def _is_metadata_query(self, query: str) -> bool:
        """Check for metadata queries (analytics_routing.mg)."""
        patterns = [
            r"\b(what|which)\s+(dimensions|measures|fields|columns)\b",
            r"\bhow\s+can\s+I\s+(aggregate|summarize|group)\b",
        ]
        return any(re.search(p, query, re.IGNORECASE) for p in patterns)
    
    async def _extract_entities(self, query: str) -> List[str]:
        """Extract entity references from query using dynamic metadata."""
        entities = []
        
        # Get entity names from dynamic metadata
        analytical_entities = await self._get_entities()
        personal_data = await self._get_personal_data()
        all_entities = list(analytical_entities.keys()) + list(personal_data.keys())
        
        for entity in all_entities:
            if re.search(rf"\b{entity}\b", query, re.IGNORECASE):
                entities.append(entity)
        
        # Also check for common SAP table names
        table_patterns = ["ACDOCA", "BSEG", "VBAK", "VBAP", "EKKO", "EKPO", "MARA", "KNA1", "LFA1"]
        for table in table_patterns:
            if table in query.upper():
                entities.append(table)
        
        return list(set(entities))
    
    def _extract_filters(self, query: str) -> Dict[str, Any]:
        """Extract temporal and entity filters (analytics_routing.mg: extract_filters)."""
        filters = {}
        
        # Date range: from YYYY-MM-DD to YYYY-MM-DD
        date_range_match = re.search(
            r"from\s+(\d{4}-\d{2}-\d{2})\s+to\s+(\d{4}-\d{2}-\d{2})",
            query, re.IGNORECASE
        )
        if date_range_match:
            filters["date_range"] = {
                "start": date_range_match.group(1),
                "end": date_range_match.group(2)
            }
        
        # Year: in YYYY
        year_match = re.search(r"\bin\s+(\d{4})\b", query, re.IGNORECASE)
        if year_match and "date_range" not in filters:
            year = year_match.group(1)
            filters["date_range"] = {
                "start": f"{year}-01-01",
                "end": f"{year}-12-31"
            }
        
        # Last N months
        months_match = re.search(r"last\s+(\d+)\s+months?", query, re.IGNORECASE)
        if months_match and "date_range" not in filters:
            months = int(months_match.group(1))
            from datetime import datetime, timedelta
            end_date = datetime.now()
            start_date = end_date - timedelta(days=30 * months)
            filters["date_range"] = {
                "start": start_date.strftime("%Y-%m-%d"),
                "end": end_date.strftime("%Y-%m-%d")
            }
        
        return filters
    
    async def _check_cache(self, query: str) -> Optional[Dict]:
        """Check ES cache for exact match (routing.mg: es_cache_lookup)."""
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"{ES_URL}/query_cache/_search",
                    json={
                        "query": {"term": {"query_hash": hash(query.lower().strip())}},
                        "size": 1
                    },
                    timeout=5.0
                )
                if response.status_code == 200:
                    hits = response.json().get("hits", {}).get("hits", [])
                    if hits:
                        return {
                            "answer": hits[0]["_source"]["answer"],
                            "score": hits[0]["_source"].get("score", 95)
                        }
        except Exception:
            pass
        return None
    
    # =========================================================================
    # Resolution Paths (from routing.mg and analytics_routing.mg)
    # =========================================================================
    
    async def resolve(self, query: str, classification: Dict) -> Dict[str, Any]:
        """
        Execute the resolution path determined by classification.
        Maps to resolve/4 rules in routing.mg and analytics_routing.mg.
        """
        
        route = classification["route"]
        
        if route == ResolutionPath.CACHE:
            return await self._resolve_cache(query)
        
        elif route == ResolutionPath.ES_FACTUAL:
            return await self._resolve_factual(query, classification)
        
        elif route == ResolutionPath.HANA_ANALYTICAL:
            return await self._resolve_hana_analytical(query, classification)
        
        elif route == ResolutionPath.HANA_HIERARCHY:
            return await self._resolve_hana_hierarchy(query, classification)
        
        elif route == ResolutionPath.ES_AGGREGATION:
            return await self._resolve_es_aggregation(query, classification)
        
        elif route == ResolutionPath.RAG_ENRICHED:
            return await self._resolve_rag(query, classification)
        
        elif route == ResolutionPath.METADATA:
            return await self._resolve_metadata(query, classification)
        
        else:
            return await self._resolve_rag(query, classification)
    
    async def _resolve_cache(self, query: str) -> Dict:
        """Resolve from cache (routing.mg: resolve cache path)."""
        result = await self._check_cache(query)
        return {"answer": result["answer"], "source": "cache", "score": result["score"]}
    
    async def _resolve_factual(self, query: str, classification: Dict) -> Dict:
        """Resolve factual lookup (routing.mg: resolve factual path)."""
        context = []
        for entity in classification["entities"]:
            try:
                async with httpx.AsyncClient() as client:
                    response = await client.post(
                        f"{ES_URL}/business_entities/_search",
                        json={
                            "query": {
                                "bool": {
                                    "must": [{"match": {"entity_type": entity}}],
                                    "should": [{"match": {"content": query}}]
                                }
                            },
                            "size": 5
                        },
                        timeout=30.0
                    )
                    if response.status_code == 200:
                        hits = response.json().get("hits", {}).get("hits", [])
                        context.extend([h["_source"] for h in hits])
            except Exception:
                pass
        
        return {"context": context, "source": "es_factual", "score": 80}
    
    async def _resolve_hana_analytical(self, query: str, classification: Dict) -> Dict:
        """Resolve via HANA analytics (analytics_routing.mg: resolve hana_analytical)."""
        # Use real HANA connector if available
        if CONNECTORS_AVAILABLE and hana_resolver:
            metadata = await self._get_metadata()
            result = await hana_resolver.resolve_analytical(classification, metadata)
            
            if result.get("results"):
                return {
                    "context": result["results"],
                    "sql": result.get("sql"),
                    "source": "hana_analytical",
                    "score": 90
                }
            elif result.get("error"):
                # Fall back to metadata-only context
                pass
        
        # Fallback: return metadata for LLM to generate query description
        entities = classification["entities"]
        dimensions = classification["dimensions"]
        measures = classification["measures"]
        filters = classification["filters"]
        
        # Get view names from dynamic metadata
        analytical_entities = await self._get_entities()
        
        # Build context for LLM
        context = {
            "source": "hana_analytical",
            "entities": entities,
            "dimensions": dimensions,
            "measures": measures,
            "filters": filters,
            "views": [analytical_entities.get(e, {}).get("view") for e in entities if e in analytical_entities],
            "note": "HANA analytical query prepared - results would be fetched from calculation views"
        }
        
        return {"context": context, "source": "hana_analytical", "score": 90}
    
    async def _resolve_hana_hierarchy(self, query: str, classification: Dict) -> Dict:
        """Resolve via HANA hierarchy (analytics_routing.mg: resolve hana_hierarchy)."""
        entities = classification["entities"]
        
        # Get hierarchies from dynamic metadata
        entity_hierarchies = await self._get_hierarchies()
        
        hierarchies = {}
        for entity in entities:
            if entity in entity_hierarchies:
                hierarchies[entity] = entity_hierarchies[entity]
        
        context = {
            "source": "hana_hierarchy",
            "hierarchies": hierarchies,
            "note": "HANA hierarchy query prepared - drill-down results would be fetched"
        }
        
        return {"context": context, "source": "hana_hierarchy", "score": 85}
    
    async def _resolve_es_aggregation(self, query: str, classification: Dict) -> Dict:
        """Resolve via ES aggregation (analytics_routing.mg: resolve es_aggregation)."""
        try:
            async with httpx.AsyncClient() as client:
                # Build aggregation query
                agg_query = {
                    "query": {"match_all": {}},
                    "aggs": {},
                    "size": 0
                }
                
                # Add dimension aggregations
                for dim in classification.get("dimensions", [])[:3]:
                    agg_query["aggs"][dim] = {"terms": {"field": f"{dim}.keyword", "size": 10}}
                
                response = await client.post(
                    f"{ES_URL}/odata_entities/_search",
                    json=agg_query,
                    timeout=30.0
                )
                
                if response.status_code == 200:
                    result = response.json()
                    return {
                        "context": result.get("aggregations", {}),
                        "source": "es_aggregation",
                        "score": 70
                    }
        except Exception:
            pass
        
        return {"context": {}, "source": "es_aggregation", "score": 50}
    
    async def _resolve_rag(self, query: str, classification: Dict) -> Dict:
        """Resolve via RAG (routing.mg: resolve rag path)."""
        context = []
        
        # Use hybrid search connector if available (BM25 + kNN)
        if CONNECTORS_AVAILABLE and hybrid_search:
            try:
                # Build filters from classification
                filters = None
                if classification.get("entities"):
                    filters = {"entity_type": classification["entities"]}
                
                results = await hybrid_search.hybrid_search(
                    index="odata_entities",
                    query=query,
                    k=5,
                    bm25_fields=["entity_name^3", "description^2", "business_context"],
                    bm25_boost=0.3,
                    knn_boost=0.7,
                    filters=filters,
                )
                
                if results:
                    context = [
                        {
                            "source": r.get("entity_name", r.get("id", "")),
                            "content": r.get("description", ""),
                            "business_context": r.get("business_context", ""),
                            "score": r.get("score", 0)
                        }
                        for r in results
                    ]
                    return {"context": context, "source": "rag_hybrid", "score": 80}
            except Exception as e:
                print(f"Hybrid search error, falling back to BM25: {e}")
        
        # Fallback: BM25-only search
        try:
            async with httpx.AsyncClient() as client:
                search_body = {
                    "query": {
                        "bool": {
                            "should": [
                                {
                                    "multi_match": {
                                        "query": query,
                                        "fields": ["entity_name^3", "description^2", "business_context"],
                                        "type": "best_fields"
                                    }
                                }
                            ]
                        }
                    },
                    "size": 5
                }
                
                # Add entity filters if available
                if classification.get("entities"):
                    search_body["query"]["bool"]["filter"] = [
                        {"terms": {"entity_type": classification["entities"]}}
                    ]
                
                response = await client.post(
                    f"{ES_URL}/odata_entities/_search",
                    json=search_body,
                    timeout=30.0
                )
                
                if response.status_code == 200:
                    results = response.json()
                    context = [
                        {
                            "source": hit["_source"].get("entity_name", ""),
                            "content": hit["_source"].get("description", ""),
                            "business_context": hit["_source"].get("business_context", ""),
                            "score": hit["_score"]
                        }
                        for hit in results.get("hits", {}).get("hits", [])
                    ]
        except Exception as e:
            print(f"RAG retrieval error: {e}")
        
        return {"context": context, "source": "rag_enriched", "score": 75}
    
    async def _resolve_metadata(self, query: str, classification: Dict) -> Dict:
        """Resolve metadata query (analytics_routing.mg)."""
        entities = classification["entities"]
        
        # Get metadata from dynamic loader
        entity_dims = await self._get_dimensions()
        entity_measures = await self._get_measures()
        entity_hierarchies = await self._get_hierarchies()
        analytical_entities = await self._get_entities()
        
        metadata = {}
        for entity in entities:
            metadata[entity] = {
                "dimensions": entity_dims.get(entity, []),
                "measures": entity_measures.get(entity, {}),
                "hierarchies": entity_hierarchies.get(entity, {}),
                "view": analytical_entities.get(entity, {}).get("view"),
            }
        
        return {"context": metadata, "source": "metadata", "score": 95}
    
    # =========================================================================
    # Prompt Augmentation and LLM Call
    # =========================================================================
    
    async def augment_prompt(self, messages: List[Message], resolution: Dict, classification: Dict) -> List[Message]:
        """Augment prompt with resolved context and classification info."""
        
        context = resolution.get("context", [])
        source = resolution.get("source", "unknown")
        
        if not context:
            return messages
        
        # Build context string based on resolution type
        if source == "metadata":
            context_str = "Available entity metadata:\n\n"
            for entity, meta in context.items():
                context_str += f"**{entity}**:\n"
                context_str += f"  - Dimensions: {', '.join(meta.get('dimensions', []))}\n"
                context_str += f"  - Measures: {', '.join(meta.get('measures', {}).keys())}\n"
                context_str += f"  - HANA View: {meta.get('view', 'N/A')}\n\n"
        
        elif source in ["hana_analytical", "hana_hierarchy"]:
            context_str = f"Query Classification: {classification['category'].value}\n"
            context_str += f"Resolution Path: {source}\n"
            context_str += f"Entities: {', '.join(classification.get('entities', []))}\n"
            context_str += f"Dimensions: {', '.join(classification.get('dimensions', []))}\n"
            context_str += f"Measures: {', '.join(classification.get('measures', []))}\n"
            if classification.get("filters"):
                context_str += f"Filters: {json.dumps(classification['filters'])}\n"
        
        elif isinstance(context, list):
            context_str = "Retrieved context:\n\n"
            for c in context:
                if isinstance(c, dict):
                    context_str += f"[{c.get('source', 'doc')}]: {c.get('content', c.get('description', str(c)))}\n\n"
                else:
                    context_str += f"{c}\n\n"
        
        else:
            context_str = f"Context: {json.dumps(context, indent=2)}"
        
        # Add GDPR warning if sensitive fields detected
        if classification.get("gdpr_fields"):
            context_str += f"\n⚠️ GDPR Note: Query may involve sensitive fields: {', '.join(classification['gdpr_fields'])}\n"
        
        # Insert context as system message
        system_context = Message(
            role="system",
            content=f"Use the following context to answer the user's question.\n\n{context_str}"
        )
        
        # Insert after first system message or at beginning
        augmented = list(messages)
        for i, msg in enumerate(augmented):
            if msg.role == "system":
                augmented.insert(i + 1, system_context)
                break
        else:
            augmented.insert(0, system_context)
        
        return augmented
    
    async def call_aicore(
        self, 
        model: str, 
        messages: List[Message],
        temperature: float = 0.7,
        max_tokens: Optional[int] = None
    ) -> ChatCompletionResponse:
        """Call SAP AI Core for LLM inference."""
        
        async with httpx.AsyncClient() as client:
            payload = {
                "model": model,
                "messages": [m.model_dump(exclude_none=True) for m in messages],
                "temperature": temperature,
            }
            if max_tokens:
                payload["max_tokens"] = max_tokens
            
            # For development, mock response
            if AICORE_URL.startswith("http://mock") or not AICORE_URL:
                return self._mock_response(model, messages)
            
            response = await client.post(
                f"{AICORE_URL}/v1/chat/completions",
                json=payload,
                headers={"Content-Type": "application/json"},
                timeout=60.0
            )
            
            if response.status_code != 200:
                raise HTTPException(
                    status_code=response.status_code,
                    detail=f"AI Core error: {response.text}"
                )
            
            return ChatCompletionResponse(**response.json())
    
    def _mock_response(self, model: str, messages: List[Message]) -> ChatCompletionResponse:
        """Generate mock response for testing."""
        
        last_user_msg = next(
            (m.content for m in reversed(messages) if m.role == "user"),
            "Hello"
        )
        
        # Extract context from system messages
        context_summary = ""
        for m in messages:
            if m.role == "system" and "context" in (m.content or "").lower():
                context_summary = f" Using context from system prompt."
                break
        
        return ChatCompletionResponse(
            id=f"chatcmpl-{datetime.now().timestamp()}",
            created=int(datetime.now().timestamp()),
            model=model,
            choices=[
                ChatCompletionChoice(
                    index=0,
                    message=Message(
                        role="assistant",
                        content=f"[Mangle Query Service] Processed query: '{last_user_msg[:100]}...'{context_summary}"
                    ),
                    finish_reason="stop"
                )
            ],
            usage=Usage(
                prompt_tokens=len(str(messages)) // 4,
                completion_tokens=50,
                total_tokens=len(str(messages)) // 4 + 50
            )
        )


# Global router instance
router = MangleRouter()


@app.post("/v1/chat/completions")
async def chat_completions(request: ChatCompletionRequest):
    """
    OpenAI-compatible chat completions endpoint.
    
    Routes queries through Mangle rules (routing.mg, analytics_routing.mg):
    1. Check semantic cache for similar queries (Phase 1)
    2. Classify query → category, route, entities, dimensions, measures
    3. Resolve via appropriate path → cache, ES, HANA, RAG
    4. Augment prompt with context
    5. Route to AI Core via batched client (Phase 1)
    6. Cache response for future queries
    
    Supports streaming via Server-Sent Events when stream=True.
    """
    
    # Extract user query
    user_query = next(
        (m.content for m in reversed(request.messages) if m.role == "user"),
        ""
    )
    
    # Classify query using Mangle rules
    classification = await router.classify_query(
        user_query, 
        request.routing_hints
    )
    
    # Phase 1: Check semantic cache first (if enabled)
    cached_response = None
    if EFFICIENCY_AVAILABLE and ENABLE_SEMANTIC_CACHE and semantic_cache and not request.stream:
        try:
            cached_response = await semantic_cache.get(user_query, {
                "category": classification["category"].value,
                "entities": classification["entities"],
            })
            if cached_response:
                # Return cached response with cache hit header
                response = ChatCompletionResponse(**cached_response)
                return response
        except Exception as e:
            print(f"Semantic cache lookup error: {e}")
    
    # Resolve via the determined path
    resolution = await router.resolve(user_query, classification)
    
    # Augment prompt with resolved context
    augmented_messages = await router.augment_prompt(
        request.messages, 
        resolution, 
        classification
    )
    
    # Handle streaming response (streaming bypasses cache and batching)
    if request.stream:
        use_mock = AICORE_URL.startswith("http://mock") or not AICORE_URL
        stream_gen = create_stream_response_generator(
            aicore_url=AICORE_URL,
            model=request.model,
            messages=[m.model_dump(exclude_none=True) for m in augmented_messages],
            temperature=request.temperature or 0.7,
            max_tokens=request.max_tokens,
            context_source=resolution.get("source", ""),
            use_mock=use_mock,
        )
        return StreamingResponse(
            stream_gen,
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Mangle-Route": classification["route"].value,
                "X-Mangle-Confidence": str(classification["confidence"]),
            }
        )
    
    # Phase 1: Use batched client for non-streaming requests (if enabled)
    if EFFICIENCY_AVAILABLE and ENABLE_REQUEST_BATCHING and get_batched_client:
        try:
            batched_client = await get_batched_client()
            payload = {
                "model": request.model,
                "messages": [m.model_dump(exclude_none=True) for m in augmented_messages],
                "temperature": request.temperature or 0.7,
            }
            if request.max_tokens:
                payload["max_tokens"] = request.max_tokens
            
            # Use mock for development
            if AICORE_URL.startswith("http://mock") or not AICORE_URL:
                response = router._mock_response(request.model, augmented_messages)
            else:
                response_data = await batched_client.complete(payload)
                response = ChatCompletionResponse(**response_data)
        except Exception as e:
            print(f"Batched client error, falling back to direct: {e}")
            response = await router.call_aicore(
                model=request.model,
                messages=augmented_messages,
                temperature=request.temperature or 0.7,
                max_tokens=request.max_tokens
            )
    else:
        # Fall back to direct AI Core call
        response = await router.call_aicore(
            model=request.model,
            messages=augmented_messages,
            temperature=request.temperature or 0.7,
            max_tokens=request.max_tokens
        )
    
    # Phase 1: Cache the response for future queries (if enabled)
    if EFFICIENCY_AVAILABLE and ENABLE_SEMANTIC_CACHE and semantic_cache and not request.stream:
        try:
            await semantic_cache.set(
                user_query,
                {
                    "category": classification["category"].value,
                    "entities": classification["entities"],
                    "route": classification["route"].value,
                },
                response.model_dump(),
            )
        except Exception as e:
            print(f"Semantic cache store error: {e}")
    
    return response


@app.get("/v1/models")
async def list_models():
    """List available models."""
    return {
        "object": "list",
        "data": [
            {"id": "gpt-4", "object": "model", "owned_by": "sap-aicore"},
            {"id": "gpt-4-turbo", "object": "model", "owned_by": "sap-aicore"},
            {"id": "gpt-3.5-turbo", "object": "model", "owned_by": "sap-aicore"},
            {"id": "claude-3-opus", "object": "model", "owned_by": "sap-aicore"},
            {"id": "claude-3-sonnet", "object": "model", "owned_by": "sap-aicore"},
        ]
    }


@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "service": "mangle-query-service",
        "timestamp": datetime.now().isoformat(),
        "endpoints": {
            "elasticsearch": ES_URL,
            "aicore": AICORE_URL,
            "hana": f"{HANA_HOST}:{HANA_PORT}" if HANA_HOST else "not configured"
        },
        "routing_rules": ["routing.mg", "analytics_routing.mg", "governance.mg", "rag_enrichment.mg"],
        "features": {
            "semantic_cache": ENABLE_SEMANTIC_CACHE and EFFICIENCY_AVAILABLE,
            "request_batching": ENABLE_REQUEST_BATCHING and EFFICIENCY_AVAILABLE,
            "semantic_classifier": ENABLE_SEMANTIC_CLASSIFIER and INTELLIGENCE_AVAILABLE,
            "speculative_execution": ENABLE_SPECULATIVE_EXECUTION and INTELLIGENCE_AVAILABLE,
            "model_selection": ENABLE_MODEL_SELECTION and INTELLIGENCE_AVAILABLE,
        }
    }


@app.get("/v1/stats")
async def get_stats():
    """Get statistics for efficiency and intelligence features (Phase 1 & 2)."""
    stats = {
        "phase1": {},
        "phase2": {},
        "features_enabled": {
            "semantic_cache": ENABLE_SEMANTIC_CACHE,
            "request_batching": ENABLE_REQUEST_BATCHING,
            "semantic_classifier": ENABLE_SEMANTIC_CLASSIFIER,
            "speculative_execution": ENABLE_SPECULATIVE_EXECUTION,
            "model_selection": ENABLE_MODEL_SELECTION,
        }
    }
    
    # Phase 1 stats
    if EFFICIENCY_AVAILABLE and semantic_cache:
        try:
            stats["phase1"]["semantic_cache"] = semantic_cache.get_stats()
        except:
            pass
    
    if EFFICIENCY_AVAILABLE and get_batched_client:
        try:
            client = await get_batched_client()
            stats["phase1"]["batch_client"] = client.get_stats()
        except:
            pass
    
    # Phase 2 stats
    if INTELLIGENCE_AVAILABLE and get_speculative_executor:
        try:
            executor = await get_speculative_executor()
            stats["phase2"]["speculative_execution"] = executor.get_stats()
        except:
            pass
    
    if INTELLIGENCE_AVAILABLE and get_model_selector:
        try:
            selector = await get_model_selector()
            stats["phase2"]["model_selection"] = selector.get_stats()
        except:
            pass
    
    return stats


@app.get("/v1/routing/classify")
async def classify_endpoint(query: str):
    """Debug endpoint to see how a query would be classified by Mangle rules."""
    classification = await router.classify_query(query)
    return {
        "query": query,
        "classification": {
            "category": classification["category"].value,
            "route": classification["route"].value,
            "confidence": classification["confidence"],
            "requires_rag": classification["requires_rag"],
            "entities": classification["entities"],
            "dimensions": classification["dimensions"],
            "measures": classification["measures"],
            "filters": classification["filters"],
            "gdpr_fields": classification["gdpr_fields"],
        }
    }


@app.get("/v1/entities")
async def list_entities():
    """List available analytical entities and their metadata (from ES)."""
    metadata = await metadata_loader.get_metadata()
    return {
        "analytical_entities": metadata.get("analytical_entities", {}),
        "dimensions": metadata.get("dimensions", {}),
        "measures": metadata.get("measures", {}),
        "hierarchies": metadata.get("hierarchies", {}),
        "source": "elasticsearch" if metadata else "fallback",
    }


@app.post("/v1/metadata/refresh")
async def refresh_metadata():
    """Force refresh of entity metadata from Elasticsearch."""
    await metadata_loader.invalidate_cache()
    metadata = await metadata_loader.get_metadata()
    return {
        "status": "refreshed",
        "entity_count": len(metadata.get("analytical_entities", {})),
        "timestamp": datetime.now().isoformat()
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)