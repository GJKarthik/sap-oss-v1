"""
OData Vocabulary Service Client

Connects mangle-query-service to odata-vocabularies-main for semantic metadata.

This connector provides:
- Entity vocabulary lookup (BKPF, ACDOCA, KNA1, etc.)
- Annotation metadata (@Semantics, @Analytics)
- Routing policy lookup (x-llm-policy)
- Data security classification

Architecture:
  mangle-query-service → odata-vocabularies-main (same repo, direct import OR HTTP)
"""

import logging
import os
from dataclasses import dataclass, field
from typing import Optional, Dict, Any, List
from enum import Enum
from pathlib import Path

import httpx

logger = logging.getLogger(__name__)


class VocabularyDeployment(Enum):
    """How vocabularies are deployed."""
    LOCAL = "local"           # Direct file access (same repo)
    SERVICE = "service"       # HTTP service (separate deployment)
    ELASTICSEARCH = "es"      # Indexed in Elasticsearch


@dataclass
class VocabularyConfig:
    """Configuration for vocabulary service."""
    
    deployment: VocabularyDeployment = VocabularyDeployment.LOCAL
    
    # Local deployment (direct file access)
    vocabulary_path: str = field(
        default_factory=lambda: os.getenv(
            "VOCABULARY_PATH",
            str(Path(__file__).parent.parent.parent / "odata-vocabularies-main")
        )
    )
    
    # Service deployment (HTTP)
    service_url: str = field(
        default_factory=lambda: os.getenv("VOCABULARY_SERVICE_URL", "http://localhost:8081")
    )
    
    # Elasticsearch deployment
    es_url: str = field(
        default_factory=lambda: os.getenv("ELASTICSEARCH_URL", "http://localhost:9200")
    )
    es_index: str = "odata_vocabulary"
    
    @classmethod
    def from_env(cls) -> "VocabularyConfig":
        """Load from environment."""
        deployment_str = os.getenv("VOCABULARY_DEPLOYMENT", "local")
        deployment = VocabularyDeployment(deployment_str) if deployment_str in [e.value for e in VocabularyDeployment] else VocabularyDeployment.LOCAL
        
        return cls(
            deployment=deployment,
            vocabulary_path=os.getenv("VOCABULARY_PATH", str(Path(__file__).parent.parent.parent / "odata-vocabularies-main")),
            service_url=os.getenv("VOCABULARY_SERVICE_URL", "http://localhost:8081"),
            es_url=os.getenv("ELASTICSEARCH_URL", "http://localhost:9200"),
        )


@dataclass
class EntityMetadata:
    """Metadata for an SAP entity."""
    name: str
    description: str
    data_security_class: str  # public, internal, confidential, restricted
    annotations: List[str]
    routing_policy: str       # aicore-ok, vllm-only, hybrid
    fields: Dict[str, Dict[str, Any]]


@dataclass
class RoutingPolicy:
    """LLM routing policy from vocabulary."""
    routing: str  # aicore-ok, vllm-only, hybrid
    default_backend: str
    audit_level: str
    rules: List[Dict[str, str]]


class VocabularyClient:
    """
    Client for OData vocabulary metadata.
    
    Supports three deployment modes:
    1. LOCAL: Direct file access when services are in same repo
    2. SERVICE: HTTP calls to standalone vocabulary service
    3. ELASTICSEARCH: Query pre-indexed vocabulary data
    """
    
    def __init__(self, config: Optional[VocabularyConfig] = None):
        self.config = config or VocabularyConfig.from_env()
        self._http_client: Optional[httpx.AsyncClient] = None
        self._vocab_cache: Dict[str, EntityMetadata] = {}
        self._xml_cache: Dict[str, Any] = {}
    
    async def __aenter__(self) -> "VocabularyClient":
        if self.config.deployment == VocabularyDeployment.SERVICE:
            self._http_client = httpx.AsyncClient(
                base_url=self.config.service_url,
                timeout=httpx.Timeout(10.0),
            )
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        if self._http_client:
            await self._http_client.aclose()
    
    # ========================================
    # Entity Lookup
    # ========================================
    
    async def get_entity_metadata(self, entity_name: str) -> Optional[EntityMetadata]:
        """
        Get metadata for an SAP entity.
        
        Examples:
            - BKPF (Accounting Document Header)
            - ACDOCA (Universal Journal Entry)
            - KNA1 (Customer Master)
        """
        # Check cache
        if entity_name in self._vocab_cache:
            return self._vocab_cache[entity_name]
        
        metadata = None
        
        if self.config.deployment == VocabularyDeployment.LOCAL:
            metadata = await self._load_local_entity(entity_name)
        elif self.config.deployment == VocabularyDeployment.SERVICE:
            metadata = await self._fetch_service_entity(entity_name)
        else:
            metadata = await self._query_es_entity(entity_name)
        
        if metadata:
            self._vocab_cache[entity_name] = metadata
        
        return metadata
    
    async def _load_local_entity(self, entity_name: str) -> Optional[EntityMetadata]:
        """Load entity from local vocabulary files."""
        # Check for YAML data product definition
        yaml_path = Path(self.config.vocabulary_path) / "data_products" / "entities" / f"{entity_name.lower()}.yaml"
        if yaml_path.exists():
            import yaml
            with open(yaml_path) as f:
                data = yaml.safe_load(f)
            return self._parse_yaml_entity(data)
        
        # Check for mangle rules
        mangle_path = Path(self.config.vocabulary_path) / "mangle" / "domain" / "vocabularies.mg"
        if mangle_path.exists():
            return await self._parse_mangle_entity(mangle_path, entity_name)
        
        # Return from known entities (hardcoded fallback)
        return self._get_known_entity(entity_name)
    
    async def _fetch_service_entity(self, entity_name: str) -> Optional[EntityMetadata]:
        """Fetch entity from vocabulary HTTP service."""
        if not self._http_client:
            raise RuntimeError("HTTP client not initialized")
        
        try:
            response = await self._http_client.get(f"/v1/entities/{entity_name}")
            if response.status_code == 404:
                return None
            response.raise_for_status()
            return self._parse_json_entity(response.json())
        except httpx.HTTPError as e:
            logger.warning(f"Failed to fetch entity {entity_name}: {e}")
            return None
    
    async def _query_es_entity(self, entity_name: str) -> Optional[EntityMetadata]:
        """Query entity from Elasticsearch."""
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{self.config.es_url}/{self.config.es_index}/_doc/{entity_name}"
            )
            if response.status_code == 404:
                return None
            response.raise_for_status()
            return self._parse_json_entity(response.json()["_source"])
    
    def _get_known_entity(self, entity_name: str) -> Optional[EntityMetadata]:
        """Return metadata for known SAP entities."""
        known_entities = {
            "ACDOCA": EntityMetadata(
                name="ACDOCA",
                description="Universal Journal Entry Line Items",
                data_security_class="confidential",
                annotations=["@Analytics.Measure", "@Semantics.amount"],
                routing_policy="hybrid",
                fields={
                    "RCLNT": {"type": "CLNT", "annotation": "@Semantics.client"},
                    "RBUKRS": {"type": "BUKRS", "annotation": "@Semantics.companyCode"},
                    "GJAHR": {"type": "GJAHR", "annotation": "@Semantics.fiscalYear"},
                    "HSL": {"type": "WERTV12", "annotation": "@Semantics.amount"},
                    "RACCT": {"type": "SAKNR", "annotation": "@Semantics.account"},
                    "KOSTL": {"type": "KOSTL", "annotation": "@Semantics.costCenter"},
                },
            ),
            "BKPF": EntityMetadata(
                name="BKPF",
                description="Accounting Document Header",
                data_security_class="confidential",
                annotations=["@Analytics.Dimension"],
                routing_policy="hybrid",
                fields={
                    "BUKRS": {"type": "BUKRS", "annotation": "@Semantics.companyCode"},
                    "BELNR": {"type": "BELNR_D", "annotation": "@Semantics.documentNumber"},
                    "GJAHR": {"type": "GJAHR", "annotation": "@Semantics.fiscalYear"},
                    "BLDAT": {"type": "BLDAT", "annotation": "@Semantics.documentDate"},
                    "BUDAT": {"type": "BUDAT", "annotation": "@Semantics.postingDate"},
                },
            ),
            "KNA1": EntityMetadata(
                name="KNA1",
                description="Customer Master - General Data",
                data_security_class="internal",
                annotations=["@Semantics.Customer"],
                routing_policy="hybrid",
                fields={
                    "KUNNR": {"type": "KUNNR", "annotation": "@Semantics.customerID"},
                    "NAME1": {"type": "NAME1_GP", "annotation": "@Semantics.name"},
                    "LAND1": {"type": "LAND1_GP", "annotation": "@Semantics.country"},
                    "REGIO": {"type": "REGIO", "annotation": "@Semantics.region"},
                },
            ),
            "VBAK": EntityMetadata(
                name="VBAK",
                description="Sales Document Header",
                data_security_class="internal",
                annotations=["@Analytics.Dimension", "@Semantics.SalesDocument"],
                routing_policy="hybrid",
                fields={
                    "VBELN": {"type": "VBELN_VA", "annotation": "@Semantics.salesDocumentNumber"},
                    "AUART": {"type": "AUART", "annotation": "@Semantics.salesDocumentType"},
                    "KUNNR": {"type": "KUNAG", "annotation": "@Semantics.soldToParty"},
                    "NETWR": {"type": "NETWR_AK", "annotation": "@Semantics.amount"},
                },
            ),
        }
        return known_entities.get(entity_name.upper())
    
    def _parse_yaml_entity(self, data: Dict) -> EntityMetadata:
        """Parse YAML entity definition."""
        return EntityMetadata(
            name=data.get("name", ""),
            description=data.get("description", ""),
            data_security_class=data.get("dataSecurityClass", "internal"),
            annotations=data.get("annotations", []),
            routing_policy=data.get("x-llm-policy", {}).get("routing", "hybrid"),
            fields=data.get("fields", {}),
        )
    
    def _parse_json_entity(self, data: Dict) -> EntityMetadata:
        """Parse JSON entity from service or ES."""
        return EntityMetadata(
            name=data.get("name", ""),
            description=data.get("description", ""),
            data_security_class=data.get("data_security_class", "internal"),
            annotations=data.get("annotations", []),
            routing_policy=data.get("routing_policy", "hybrid"),
            fields=data.get("fields", {}),
        )
    
    async def _parse_mangle_entity(self, mangle_path: Path, entity_name: str) -> Optional[EntityMetadata]:
        """Parse entity from mangle vocabulary rules."""
        # Simplified mangle parsing - in production use proper parser
        content = mangle_path.read_text()
        if entity_name.lower() in content.lower():
            return self._get_known_entity(entity_name)
        return None
    
    # ========================================
    # Routing Policy
    # ========================================
    
    async def get_routing_policy(self, entity_name: str) -> Optional[RoutingPolicy]:
        """Get LLM routing policy for an entity."""
        metadata = await self.get_entity_metadata(entity_name)
        if not metadata:
            return None
        
        return RoutingPolicy(
            routing=metadata.routing_policy,
            default_backend="aicore" if metadata.routing_policy == "aicore-ok" else "hybrid",
            audit_level="enhanced" if metadata.data_security_class in ["confidential", "restricted"] else "basic",
            rules=[
                {
                    "condition": f"{entity_name.lower()}_query",
                    "backend": "vllm" if metadata.data_security_class in ["confidential", "restricted"] else "aicore",
                }
            ],
        )
    
    async def should_use_vllm(self, entity_name: str) -> bool:
        """Check if entity queries should use vLLM (on-premise)."""
        metadata = await self.get_entity_metadata(entity_name)
        if not metadata:
            return False
        return metadata.data_security_class in ["confidential", "restricted"]
    
    async def should_use_aicore(self, entity_name: str) -> bool:
        """Check if entity queries can use AI Core (cloud)."""
        metadata = await self.get_entity_metadata(entity_name)
        if not metadata:
            return True
        return metadata.routing_policy == "aicore-ok"
    
    # ========================================
    # Annotation Lookup
    # ========================================
    
    async def get_field_annotations(self, entity_name: str, field_name: str) -> Dict[str, str]:
        """Get annotations for a specific field."""
        metadata = await self.get_entity_metadata(entity_name)
        if not metadata:
            return {}
        
        field_data = metadata.fields.get(field_name, {})
        return {
            "annotation": field_data.get("annotation", ""),
            "type": field_data.get("type", ""),
        }
    
    async def search_by_annotation(self, annotation: str) -> List[Dict[str, Any]]:
        """Search entities and fields by annotation type."""
        results = []
        for entity_name in ["ACDOCA", "BKPF", "KNA1", "VBAK", "VBAP", "EKKO", "EKPO"]:
            metadata = await self.get_entity_metadata(entity_name)
            if not metadata:
                continue
            
            # Check entity annotations
            if annotation in str(metadata.annotations):
                results.append({
                    "entity": entity_name,
                    "field": None,
                    "annotation": annotation,
                    "description": metadata.description,
                })
            
            # Check field annotations
            for field_name, field_data in metadata.fields.items():
                if annotation in field_data.get("annotation", ""):
                    results.append({
                        "entity": entity_name,
                        "field": field_name,
                        "annotation": field_data.get("annotation"),
                        "type": field_data.get("type"),
                    })
        
        return results
    
    # ========================================
    # Health Check
    # ========================================
    
    async def health_check(self) -> Dict[str, Any]:
        """Check vocabulary service health."""
        if self.config.deployment == VocabularyDeployment.LOCAL:
            vocab_path = Path(self.config.vocabulary_path)
            return {
                "status": "healthy" if vocab_path.exists() else "unhealthy",
                "deployment": "local",
                "path": str(vocab_path),
                "exists": vocab_path.exists(),
            }
        elif self.config.deployment == VocabularyDeployment.SERVICE:
            try:
                if self._http_client:
                    response = await self._http_client.get("/health")
                    return {
                        "status": "healthy" if response.status_code == 200 else "unhealthy",
                        "deployment": "service",
                        "url": self.config.service_url,
                    }
            except Exception as e:
                return {
                    "status": "unhealthy",
                    "deployment": "service",
                    "error": str(e),
                }
        else:
            try:
                async with httpx.AsyncClient() as client:
                    response = await client.get(f"{self.config.es_url}/_cluster/health")
                    return {
                        "status": "healthy" if response.status_code == 200 else "unhealthy",
                        "deployment": "elasticsearch",
                        "url": self.config.es_url,
                    }
            except Exception as e:
                return {
                    "status": "unhealthy",
                    "deployment": "elasticsearch",
                    "error": str(e),
                }
        
        return {"status": "unknown"}


# ========================================
# Singleton Instance
# ========================================

_vocabulary_client: Optional[VocabularyClient] = None


async def get_vocabulary_client() -> VocabularyClient:
    """Get singleton vocabulary client."""
    global _vocabulary_client
    
    if _vocabulary_client is None:
        _vocabulary_client = VocabularyClient()
        await _vocabulary_client.__aenter__()
    
    return _vocabulary_client


# ========================================
# Exports
# ========================================

__all__ = [
    "VocabularyClient",
    "VocabularyConfig",
    "VocabularyDeployment",
    "EntityMetadata",
    "RoutingPolicy",
    "get_vocabulary_client",
]