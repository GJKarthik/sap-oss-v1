"""
Dynamic Entity Metadata Loader.

Fetches entity metadata (dimensions, measures, hierarchies, GDPR fields)
from Elasticsearch at runtime instead of hardcoding.

The metadata is populated by:
1. OData vocabulary MCP server
2. HANA schema introspection
3. Manual configuration files
"""

import httpx
import json
import os
from typing import Dict, List, Any, Optional
from datetime import datetime, timedelta
import asyncio


ES_URL = os.getenv("ELASTICSEARCH_URL", "http://elasticsearch:9200")

# Cache settings
CACHE_TTL_SECONDS = 300  # 5 minutes


class EntityMetadataLoader:
    """
    Loads entity metadata dynamically from Elasticsearch.
    
    Metadata is stored in these indices:
    - entity_registry: Core entity definitions (views, schemas)
    - entity_dimensions: Dimension mappings
    - entity_measures: Measure definitions with aggregation types
    - entity_hierarchies: Hierarchy configurations
    - entity_gdpr: Personal data field classifications
    """
    
    def __init__(self):
        self._cache: Dict[str, Any] = {}
        self._cache_timestamp: Optional[datetime] = None
        self._loading = False
    
    async def get_metadata(self) -> Dict[str, Any]:
        """Get all entity metadata, using cache if available."""
        
        # Check cache validity
        if self._cache and self._cache_timestamp:
            age = datetime.now() - self._cache_timestamp
            if age < timedelta(seconds=CACHE_TTL_SECONDS):
                return self._cache
        
        # Load fresh metadata
        await self._refresh_metadata()
        return self._cache
    
    async def _refresh_metadata(self) -> None:
        """Refresh metadata from Elasticsearch."""
        
        if self._loading:
            # Wait for in-progress load
            while self._loading:
                await asyncio.sleep(0.1)
            return
        
        self._loading = True
        try:
            metadata = {
                "analytical_entities": await self._load_entities(),
                "dimensions": await self._load_dimensions(),
                "measures": await self._load_measures(),
                "hierarchies": await self._load_hierarchies(),
                "personal_data": await self._load_gdpr_fields(),
            }
            
            self._cache = metadata
            self._cache_timestamp = datetime.now()
        finally:
            self._loading = False
    
    async def _load_entities(self) -> Dict[str, Dict[str, str]]:
        """Load analytical entity definitions from ES."""
        
        entities = {}
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"{ES_URL}/entity_registry/_search",
                    json={
                        "query": {"match_all": {}},
                        "size": 1000
                    },
                    timeout=30.0
                )
                
                if response.status_code == 200:
                    hits = response.json().get("hits", {}).get("hits", [])
                    for hit in hits:
                        src = hit["_source"]
                        entity_name = src.get("entity_name", hit["_id"])
                        entities[entity_name] = {
                            "view": src.get("hana_view", ""),
                            "schema": src.get("hana_schema", ""),
                            "table": src.get("table_name", ""),
                            "description": src.get("description", ""),
                            "namespace": src.get("namespace", ""),
                        }
        except Exception as e:
            print(f"Failed to load entities from ES: {e}")
            # Return fallback defaults
            entities = self._get_fallback_entities()
        
        return entities
    
    async def _load_dimensions(self) -> Dict[str, List[str]]:
        """Load dimension mappings from ES."""
        
        dimensions = {}
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"{ES_URL}/entity_dimensions/_search",
                    json={
                        "query": {"match_all": {}},
                        "size": 5000,
                        "aggs": {
                            "by_entity": {
                                "terms": {"field": "entity_name.keyword", "size": 500},
                                "aggs": {
                                    "dims": {"terms": {"field": "dimension_name.keyword", "size": 100}}
                                }
                            }
                        }
                    },
                    timeout=30.0
                )
                
                if response.status_code == 200:
                    result = response.json()
                    for bucket in result.get("aggregations", {}).get("by_entity", {}).get("buckets", []):
                        entity = bucket["key"]
                        dims = [d["key"] for d in bucket.get("dims", {}).get("buckets", [])]
                        dimensions[entity] = dims
        except Exception as e:
            print(f"Failed to load dimensions from ES: {e}")
            dimensions = self._get_fallback_dimensions()
        
        return dimensions
    
    async def _load_measures(self) -> Dict[str, Dict[str, str]]:
        """Load measure definitions from ES."""
        
        measures = {}
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"{ES_URL}/entity_measures/_search",
                    json={
                        "query": {"match_all": {}},
                        "size": 5000
                    },
                    timeout=30.0
                )
                
                if response.status_code == 200:
                    hits = response.json().get("hits", {}).get("hits", [])
                    for hit in hits:
                        src = hit["_source"]
                        entity = src.get("entity_name", "")
                        measure = src.get("measure_name", "")
                        agg_type = src.get("aggregation_type", "SUM")
                        
                        if entity not in measures:
                            measures[entity] = {}
                        measures[entity][measure] = agg_type
        except Exception as e:
            print(f"Failed to load measures from ES: {e}")
            measures = self._get_fallback_measures()
        
        return measures
    
    async def _load_hierarchies(self) -> Dict[str, Dict[str, tuple]]:
        """Load hierarchy configurations from ES."""
        
        hierarchies = {}
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"{ES_URL}/entity_hierarchies/_search",
                    json={
                        "query": {"match_all": {}},
                        "size": 1000
                    },
                    timeout=30.0
                )
                
                if response.status_code == 200:
                    hits = response.json().get("hits", {}).get("hits", [])
                    for hit in hits:
                        src = hit["_source"]
                        entity = src.get("entity_name", "")
                        hierarchy_name = src.get("hierarchy_name", "")
                        node_col = src.get("node_column", "")
                        parent_col = src.get("parent_column", "")
                        
                        if entity not in hierarchies:
                            hierarchies[entity] = {}
                        hierarchies[entity][hierarchy_name] = (node_col, parent_col)
        except Exception as e:
            print(f"Failed to load hierarchies from ES: {e}")
            hierarchies = self._get_fallback_hierarchies()
        
        return hierarchies
    
    async def _load_gdpr_fields(self) -> Dict[str, Dict[str, str]]:
        """Load GDPR/personal data field classifications from ES."""
        
        gdpr_fields = {}
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"{ES_URL}/entity_gdpr/_search",
                    json={
                        "query": {"match_all": {}},
                        "size": 5000
                    },
                    timeout=30.0
                )
                
                if response.status_code == 200:
                    hits = response.json().get("hits", {}).get("hits", [])
                    for hit in hits:
                        src = hit["_source"]
                        entity = src.get("entity_name", "")
                        field = src.get("field_name", "")
                        sensitivity = src.get("sensitivity", "personal")
                        
                        if entity not in gdpr_fields:
                            gdpr_fields[entity] = {}
                        gdpr_fields[entity][field] = sensitivity
        except Exception as e:
            print(f"Failed to load GDPR fields from ES: {e}")
            gdpr_fields = self._get_fallback_gdpr()
        
        return gdpr_fields
    
    # =========================================================================
    # Fallback defaults (used when ES is unavailable or indices don't exist)
    # =========================================================================
    
    def _get_fallback_entities(self) -> Dict[str, Dict[str, str]]:
        """Fallback entity definitions."""
        return {
            "SalesOrder": {"view": "CV_SALES_ORDER", "schema": "ANALYTICS"},
            "Material": {"view": "CV_MATERIAL_ANALYTICS", "schema": "ANALYTICS"},
            "FinancialStatement": {"view": "CV_FIN_STATEMENT", "schema": "FINANCE"},
            "CostCenter": {"view": "CV_COST_CENTER_ANALYSIS", "schema": "CONTROLLING"},
            "ACDOCA": {"view": "ACDOCA", "schema": "FINANCE"},
            "Customer": {"view": "CV_CUSTOMER", "schema": "SD"},
            "Vendor": {"view": "CV_VENDOR", "schema": "MM"},
        }
    
    def _get_fallback_dimensions(self) -> Dict[str, List[str]]:
        """Fallback dimension mappings."""
        return {
            "SalesOrder": ["Region", "Customer", "Product", "OrderDate", "SalesOrg"],
            "CostCenter": ["CostCenterHierarchy", "FiscalYear", "CompanyCode"],
            "ACDOCA": ["CompanyCode", "FiscalYear", "GLAccount", "CostCenter", "ProfitCenter"],
            "Material": ["MaterialGroup", "Plant", "StorageLocation"],
        }
    
    def _get_fallback_measures(self) -> Dict[str, Dict[str, str]]:
        """Fallback measure definitions."""
        return {
            "SalesOrder": {"NetAmount": "SUM", "Quantity": "SUM", "OrderCount": "COUNT", "AvgOrderValue": "AVG"},
            "CostCenter": {"ActualCosts": "SUM", "PlanCosts": "SUM", "Variance": "SUM"},
            "ACDOCA": {"Amount": "SUM", "LocalAmount": "SUM", "Quantity": "SUM"},
            "Material": {"Stock": "SUM", "Value": "SUM"},
        }
    
    def _get_fallback_hierarchies(self) -> Dict[str, Dict[str, tuple]]:
        """Fallback hierarchy configurations."""
        return {
            "CostCenter": {"CostCenterHierarchy": ("CostCenter", "ParentCostCenter")},
            "Material": {"ProductHierarchy": ("MaterialGroup", "ParentMaterialGroup")},
            "GLAccount": {"GLAccountHierarchy": ("GLAccount", "ParentGLAccount")},
        }
    
    def _get_fallback_gdpr(self) -> Dict[str, Dict[str, str]]:
        """Fallback GDPR field classifications."""
        return {
            "Employee": {"Name": "personal", "Email": "personal", "SSN": "sensitive", "Salary": "sensitive"},
            "BusinessPartner": {"ContactName": "personal", "Phone": "personal", "Email": "personal"},
            "Customer": {"Name": "personal", "Phone": "personal"},
        }
    
    async def get_entity_info(self, entity_name: str) -> Optional[Dict[str, Any]]:
        """Get full metadata for a specific entity."""
        
        metadata = await self.get_metadata()
        
        if entity_name not in metadata["analytical_entities"]:
            return None
        
        return {
            "entity": entity_name,
            "view": metadata["analytical_entities"].get(entity_name, {}),
            "dimensions": metadata["dimensions"].get(entity_name, []),
            "measures": metadata["measures"].get(entity_name, {}),
            "hierarchies": metadata["hierarchies"].get(entity_name, {}),
            "personal_data": metadata["personal_data"].get(entity_name, {}),
        }
    
    async def invalidate_cache(self) -> None:
        """Force cache invalidation."""
        self._cache = {}
        self._cache_timestamp = None


# Singleton instance
metadata_loader = EntityMetadataLoader()