"""
Elasticsearch Client for OData Vocabularies

Production-ready Elasticsearch integration for vocabulary search and indexing.
"""

import logging
from typing import Any, Dict, List, Optional
from dataclasses import dataclass
from datetime import datetime
import json

logger = logging.getLogger(__name__)


@dataclass
class ESStats:
    """Elasticsearch client statistics"""
    total_requests: int = 0
    failed_requests: int = 0
    avg_response_time_ms: float = 0
    last_error: Optional[str] = None
    last_error_time: Optional[datetime] = None
    indices_created: int = 0


class ElasticsearchClient:
    """
    Elasticsearch client for OData vocabulary operations.
    
    Features:
    - Index management with vocabulary mappings
    - Bulk document indexing
    - Full-text and semantic search
    - Vocabulary-aware query building
    """
    
    def __init__(self, config: "ElasticsearchConfig"):
        """
        Initialize Elasticsearch client.
        
        Args:
            config: ElasticsearchConfig from settings
        """
        self.config = config
        self.stats = ESStats()
        self._client = None
        self._connected = False
        self._es_available = False
        
        # Try to import elasticsearch
        try:
            from elasticsearch import Elasticsearch
            self._Elasticsearch = Elasticsearch
            self._es_available = True
        except ImportError:
            logger.warning("elasticsearch not installed - ES features will be simulated")
    
    def connect(self) -> bool:
        """
        Establish connection to Elasticsearch.
        
        Returns:
            True if connection successful
        """
        if not self._es_available:
            logger.warning("elasticsearch package not available - using simulation mode")
            self._connected = True
            return True
        
        try:
            # Build connection kwargs
            kwargs = {
                "request_timeout": self.config.request_timeout,
                "verify_certs": self.config.verify_certs
            }
            
            if self.config.cloud_id:
                kwargs["cloud_id"] = self.config.cloud_id
            else:
                kwargs["hosts"] = self.config.hosts
            
            if self.config.api_key:
                kwargs["api_key"] = self.config.api_key
            elif self.config.username and self.config.password:
                kwargs["basic_auth"] = (self.config.username, self.config.password)
            
            if self.config.ca_certs:
                kwargs["ca_certs"] = self.config.ca_certs
            
            self._client = self._Elasticsearch(**kwargs)
            
            # Test connection
            info = self._client.info()
            logger.info(f"Connected to Elasticsearch: {info['version']['number']}")
            self._connected = True
            return True
            
        except Exception as e:
            self.stats.failed_requests += 1
            self.stats.last_error = str(e)
            self.stats.last_error_time = datetime.utcnow()
            logger.error(f"Failed to connect to Elasticsearch: {e}")
            return False
    
    def create_vocabulary_index(self, index_name: str = None) -> Dict:
        """
        Create index with vocabulary-optimized mappings.
        
        Args:
            index_name: Index name (defaults to config prefix + "_vocabulary")
            
        Returns:
            Creation result
        """
        index_name = index_name or f"{self.config.index_prefix}_vocabulary"
        
        mapping = {
            "settings": {
                "number_of_shards": 1,
                "number_of_replicas": 1,
                "analysis": {
                    "analyzer": {
                        "vocabulary_analyzer": {
                            "type": "custom",
                            "tokenizer": "standard",
                            "filter": ["lowercase", "asciifolding", "vocabulary_synonyms"]
                        }
                    },
                    "filter": {
                        "vocabulary_synonyms": {
                            "type": "synonym",
                            "synonyms": [
                                "ui, user interface, front end",
                                "api, application programming interface",
                                "crud, create read update delete",
                                "odata, open data protocol"
                            ]
                        }
                    }
                }
            },
            "mappings": {
                "properties": {
                    "term_name": {"type": "keyword"},
                    "qualified_name": {"type": "keyword"},
                    "vocabulary": {"type": "keyword"},
                    "namespace": {"type": "keyword"},
                    "term_type": {"type": "keyword"},
                    "description": {
                        "type": "text",
                        "analyzer": "vocabulary_analyzer"
                    },
                    "applies_to": {"type": "keyword"},
                    "base_type": {"type": "keyword"},
                    "properties": {
                        "type": "nested",
                        "properties": {
                            "name": {"type": "keyword"},
                            "type": {"type": "keyword"},
                            "description": {"type": "text"}
                        }
                    },
                    "embedding": {
                        "type": "dense_vector",
                        "dims": 1536,
                        "index": True,
                        "similarity": "cosine"
                    },
                    "created_at": {"type": "date"},
                    "updated_at": {"type": "date"}
                }
            }
        }
        
        return self._create_index(index_name, mapping)
    
    def create_entity_index(self, index_name: str = None) -> Dict:
        """
        Create index for OData entities.
        
        Args:
            index_name: Index name (defaults to config prefix + "_entities")
            
        Returns:
            Creation result
        """
        index_name = index_name or f"{self.config.index_prefix}_entities"
        
        mapping = {
            "settings": {
                "number_of_shards": 2,
                "number_of_replicas": 1
            },
            "mappings": {
                "properties": {
                    "entity_type": {"type": "keyword"},
                    "entity_id": {"type": "keyword"},
                    "schema": {"type": "keyword"},
                    "service": {"type": "keyword"},
                    "properties": {
                        "type": "nested",
                        "properties": {
                            "name": {"type": "keyword"},
                            "type": {"type": "keyword"},
                            "nullable": {"type": "boolean"},
                            "is_key": {"type": "boolean"}
                        }
                    },
                    "annotations": {
                        "type": "object",
                        "enabled": True
                    },
                    "vocabulary_context": {"type": "keyword"},
                    "gdpr_classification": {
                        "properties": {
                            "is_data_subject": {"type": "boolean"},
                            "contains_personal_data": {"type": "boolean"},
                            "contains_sensitive_data": {"type": "boolean"},
                            "personal_fields": {"type": "keyword"},
                            "sensitive_fields": {"type": "keyword"}
                        }
                    },
                    "embedding": {
                        "type": "dense_vector",
                        "dims": 1536,
                        "index": True,
                        "similarity": "cosine"
                    },
                    "source_system": {"type": "keyword"},
                    "created_at": {"type": "date"},
                    "updated_at": {"type": "date"}
                }
            }
        }
        
        return self._create_index(index_name, mapping)
    
    def create_audit_index(self, index_name: str = None) -> Dict:
        """
        Create index for audit logs.
        
        Args:
            index_name: Index name (defaults to config prefix + "_audit")
            
        Returns:
            Creation result
        """
        index_name = index_name or f"{self.config.index_prefix}_audit"
        
        mapping = {
            "settings": {
                "number_of_shards": 1,
                "number_of_replicas": 1,
                "index.lifecycle.name": "audit_retention_policy"
            },
            "mappings": {
                "properties": {
                    "timestamp": {"type": "date"},
                    "query_id": {"type": "keyword"},
                    "event_type": {"type": "keyword"},
                    "query": {"type": "text"},
                    "query_hash": {"type": "keyword"},
                    "resolution_path": {"type": "keyword"},
                    "entities_accessed": {
                        "type": "nested",
                        "properties": {
                            "entity_type": {"type": "keyword"},
                            "entity_id": {"type": "keyword"},
                            "access_level": {"type": "keyword"}
                        }
                    },
                    "personal_data_audit": {
                        "properties": {
                            "data_subject_accessed": {"type": "boolean"},
                            "personal_fields": {"type": "keyword"},
                            "sensitive_fields": {"type": "keyword"},
                            "legal_basis": {"type": "keyword"},
                            "purpose": {"type": "keyword"}
                        }
                    },
                    "user_id": {"type": "keyword"},
                    "user_role": {"type": "keyword"},
                    "client_ip": {"type": "ip"},
                    "tool_name": {"type": "keyword"},
                    "duration_ms": {"type": "float"},
                    "success": {"type": "boolean"},
                    "error_message": {"type": "text"}
                }
            }
        }
        
        return self._create_index(index_name, mapping)
    
    def _create_index(self, index_name: str, mapping: Dict) -> Dict:
        """Create index with mapping"""
        if not self._es_available:
            self.stats.indices_created += 1
            return {"simulated": True, "index": index_name, "acknowledged": True}
        
        if not self._client:
            return {"error": "Not connected"}
        
        try:
            # Check if index exists
            if self._client.indices.exists(index=index_name):
                return {"exists": True, "index": index_name}
            
            response = self._client.indices.create(index=index_name, body=mapping)
            self.stats.indices_created += 1
            logger.info(f"Created index: {index_name}")
            return {"acknowledged": response.get("acknowledged"), "index": index_name}
            
        except Exception as e:
            self.stats.failed_requests += 1
            self.stats.last_error = str(e)
            self.stats.last_error_time = datetime.utcnow()
            return {"error": str(e)}
    
    def index_vocabulary_term(self, term: Dict, index_name: str = None) -> Dict:
        """
        Index a vocabulary term.
        
        Args:
            term: Term document
            index_name: Target index
            
        Returns:
            Indexing result
        """
        index_name = index_name or f"{self.config.index_prefix}_vocabulary"
        term["updated_at"] = datetime.utcnow().isoformat()
        
        if not self._es_available:
            return {"simulated": True, "result": "created", "_id": term.get("qualified_name")}
        
        if not self._client:
            return {"error": "Not connected"}
        
        try:
            doc_id = term.get("qualified_name", term.get("term_name"))
            response = self._client.index(index=index_name, id=doc_id, document=term)
            self.stats.total_requests += 1
            return {"result": response.get("result"), "_id": response.get("_id")}
        except Exception as e:
            self.stats.failed_requests += 1
            return {"error": str(e)}
    
    def bulk_index(self, documents: List[Dict], index_name: str) -> Dict:
        """
        Bulk index documents.
        
        Args:
            documents: List of documents
            index_name: Target index
            
        Returns:
            Bulk result
        """
        if not self._es_available:
            return {"simulated": True, "indexed": len(documents), "errors": False}
        
        if not self._client:
            return {"error": "Not connected"}
        
        try:
            from elasticsearch.helpers import bulk
            
            actions = []
            for doc in documents:
                action = {
                    "_index": index_name,
                    "_id": doc.get("id") or doc.get("qualified_name") or doc.get("entity_id"),
                    "_source": doc
                }
                actions.append(action)
            
            success, errors = bulk(self._client, actions, raise_on_error=False)
            self.stats.total_requests += 1
            
            return {
                "indexed": success,
                "errors": len(errors) > 0,
                "error_count": len(errors) if errors else 0
            }
            
        except Exception as e:
            self.stats.failed_requests += 1
            return {"error": str(e)}
    
    def search(self, query: str, index_name: str = None, size: int = 10) -> Dict:
        """
        Search for vocabulary terms or entities.
        
        Args:
            query: Search query
            index_name: Index to search
            size: Max results
            
        Returns:
            Search results
        """
        index_name = index_name or f"{self.config.index_prefix}_*"
        
        if not self._es_available:
            return self._simulate_search(query, size)
        
        if not self._client:
            return {"error": "Not connected"}
        
        try:
            body = {
                "query": {
                    "multi_match": {
                        "query": query,
                        "fields": ["term_name^3", "description^2", "qualified_name", "vocabulary"],
                        "type": "best_fields",
                        "fuzziness": "AUTO"
                    }
                },
                "size": size,
                "highlight": {
                    "fields": {
                        "description": {},
                        "term_name": {}
                    }
                }
            }
            
            response = self._client.search(index=index_name, body=body)
            self.stats.total_requests += 1
            
            hits = []
            for hit in response["hits"]["hits"]:
                hits.append({
                    "id": hit["_id"],
                    "score": hit["_score"],
                    "source": hit["_source"],
                    "highlights": hit.get("highlight", {})
                })
            
            return {
                "total": response["hits"]["total"]["value"],
                "hits": hits,
                "took_ms": response["took"]
            }
            
        except Exception as e:
            self.stats.failed_requests += 1
            return {"error": str(e)}
    
    def semantic_search(self, embedding: List[float], index_name: str = None, size: int = 10) -> Dict:
        """
        Semantic search using vector similarity.
        
        Args:
            embedding: Query embedding vector
            index_name: Index to search
            size: Max results
            
        Returns:
            Search results
        """
        index_name = index_name or f"{self.config.index_prefix}_vocabulary"
        
        if not self._es_available:
            return {"simulated": True, "hits": [], "total": 0}
        
        if not self._client:
            return {"error": "Not connected"}
        
        try:
            body = {
                "knn": {
                    "field": "embedding",
                    "query_vector": embedding,
                    "k": size,
                    "num_candidates": size * 10
                }
            }
            
            response = self._client.search(index=index_name, body=body)
            self.stats.total_requests += 1
            
            hits = []
            for hit in response["hits"]["hits"]:
                hits.append({
                    "id": hit["_id"],
                    "score": hit["_score"],
                    "source": hit["_source"]
                })
            
            return {
                "total": response["hits"]["total"]["value"],
                "hits": hits,
                "took_ms": response["took"]
            }
            
        except Exception as e:
            self.stats.failed_requests += 1
            return {"error": str(e)}
    
    def _simulate_search(self, query: str, size: int) -> Dict:
        """Simulate search for testing"""
        query_lower = query.lower()
        
        simulated_hits = [
            {
                "id": "UI.LineItem",
                "score": 0.95,
                "source": {
                    "term_name": "LineItem",
                    "vocabulary": "UI",
                    "description": "Collection of line items for a list report"
                }
            },
            {
                "id": "Common.Label",
                "score": 0.88,
                "source": {
                    "term_name": "Label",
                    "vocabulary": "Common",
                    "description": "Human-readable label for a field"
                }
            }
        ]
        
        return {
            "total": len(simulated_hits),
            "hits": simulated_hits[:size],
            "took_ms": 25,
            "simulated": True
        }
    
    def get_stats(self) -> Dict:
        """Get client statistics"""
        return {
            "total_requests": self.stats.total_requests,
            "failed_requests": self.stats.failed_requests,
            "avg_response_time_ms": round(self.stats.avg_response_time_ms, 2),
            "indices_created": self.stats.indices_created,
            "last_error": self.stats.last_error,
            "last_error_time": self.stats.last_error_time.isoformat() if self.stats.last_error_time else None,
            "es_available": self._es_available,
            "connected": self._connected
        }
    
    def close(self):
        """Close Elasticsearch connection"""
        if self._client:
            self._client.close()
        self._connected = False
        logger.info("Elasticsearch connection closed")


# Singleton instance
_client: Optional[ElasticsearchClient] = None


def get_es_client(config: "ElasticsearchConfig" = None) -> ElasticsearchClient:
    """Get or create the ElasticsearchClient singleton"""
    global _client
    if _client is None:
        if config is None:
            from config.settings import get_settings
            config = get_settings().elasticsearch
        _client = ElasticsearchClient(config)
    return _client