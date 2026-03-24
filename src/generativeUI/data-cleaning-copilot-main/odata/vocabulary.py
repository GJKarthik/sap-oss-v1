# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
OData Vocabulary Integration for Data Cleaning Copilot

Provides semantic type hints for columns based on OData vocabularies:
- Identifies email, phone, URL fields
- Recognizes currency, date, timestamp types
- Detects PII fields for routing decisions
- Provides validation rules based on semantic types
"""

import json
import os
import logging
import urllib.request
import urllib.error
from typing import Any, Dict, List, Optional, Tuple
from dataclasses import dataclass, field
from enum import Enum

logger = logging.getLogger("data-cleaning-copilot.odata")

# =============================================================================
# Semantic Types (from OData Common vocabulary)
# =============================================================================

class SemanticType(Enum):
    """OData semantic types mapped to validation rules."""
    
    # Contact information (PII)
    EMAIL = "email"
    PHONE = "phone"
    URL = "url"
    
    # Personal identifiers (PII)
    PERSON_NAME = "person_name"
    ADDRESS = "address"
    CITY = "city"
    COUNTRY = "country"
    POSTAL_CODE = "postal_code"
    
    # Financial (Sensitive)
    CURRENCY = "currency"
    AMOUNT = "amount"
    PERCENTAGE = "percentage"
    
    # Temporal
    DATE = "date"
    TIME = "time"
    DATETIME = "datetime"
    TIMESTAMP = "timestamp"
    
    # Identifiers
    UUID = "uuid"
    ID = "id"
    CODE = "code"
    
    # Text
    TEXT = "text"
    DESCRIPTION = "description"
    TITLE = "title"
    
    # Binary
    IMAGE = "image"
    DOCUMENT = "document"
    
    # Unknown
    UNKNOWN = "unknown"


# Mapping column name patterns to semantic types
COLUMN_NAME_PATTERNS: Dict[str, SemanticType] = {
    # Email
    "email": SemanticType.EMAIL,
    "e_mail": SemanticType.EMAIL,
    "mail": SemanticType.EMAIL,
    "emailaddress": SemanticType.EMAIL,
    
    # Phone
    "phone": SemanticType.PHONE,
    "telephone": SemanticType.PHONE,
    "mobile": SemanticType.PHONE,
    "fax": SemanticType.PHONE,
    "cell": SemanticType.PHONE,
    
    # URL
    "url": SemanticType.URL,
    "website": SemanticType.URL,
    "link": SemanticType.URL,
    "homepage": SemanticType.URL,
    
    # Names (PII)
    "firstname": SemanticType.PERSON_NAME,
    "first_name": SemanticType.PERSON_NAME,
    "lastname": SemanticType.PERSON_NAME,
    "last_name": SemanticType.PERSON_NAME,
    "fullname": SemanticType.PERSON_NAME,
    "full_name": SemanticType.PERSON_NAME,
    "name": SemanticType.PERSON_NAME,
    
    # Address (PII)
    "address": SemanticType.ADDRESS,
    "street": SemanticType.ADDRESS,
    "city": SemanticType.CITY,
    "country": SemanticType.COUNTRY,
    "postalcode": SemanticType.POSTAL_CODE,
    "postal_code": SemanticType.POSTAL_CODE,
    "zipcode": SemanticType.POSTAL_CODE,
    "zip_code": SemanticType.POSTAL_CODE,
    "zip": SemanticType.POSTAL_CODE,
    
    # Financial
    "currency": SemanticType.CURRENCY,
    "currencycode": SemanticType.CURRENCY,
    "currency_code": SemanticType.CURRENCY,
    "amount": SemanticType.AMOUNT,
    "price": SemanticType.AMOUNT,
    "total": SemanticType.AMOUNT,
    "subtotal": SemanticType.AMOUNT,
    "cost": SemanticType.AMOUNT,
    "fee": SemanticType.AMOUNT,
    "percentage": SemanticType.PERCENTAGE,
    "percent": SemanticType.PERCENTAGE,
    "rate": SemanticType.PERCENTAGE,
    
    # Temporal
    "date": SemanticType.DATE,
    "createdat": SemanticType.TIMESTAMP,
    "created_at": SemanticType.TIMESTAMP,
    "updatedat": SemanticType.TIMESTAMP,
    "updated_at": SemanticType.TIMESTAMP,
    "modifiedat": SemanticType.TIMESTAMP,
    "modified_at": SemanticType.TIMESTAMP,
    "timestamp": SemanticType.TIMESTAMP,
    "time": SemanticType.TIME,
    "datetime": SemanticType.DATETIME,
    
    # Identifiers
    "id": SemanticType.ID,
    "uuid": SemanticType.UUID,
    "guid": SemanticType.UUID,
    "code": SemanticType.CODE,
    "key": SemanticType.ID,
    
    # Text
    "description": SemanticType.DESCRIPTION,
    "title": SemanticType.TITLE,
    "text": SemanticType.TEXT,
    "comment": SemanticType.TEXT,
    "note": SemanticType.TEXT,
    "notes": SemanticType.TEXT,
    "remarks": SemanticType.TEXT,
}

# PII semantic types
PII_TYPES = frozenset([
    SemanticType.EMAIL,
    SemanticType.PHONE,
    SemanticType.PERSON_NAME,
    SemanticType.ADDRESS,
    SemanticType.CITY,
    SemanticType.POSTAL_CODE,
])

# Sensitive (but not PII) types
SENSITIVE_TYPES = frozenset([
    SemanticType.CURRENCY,
    SemanticType.AMOUNT,
])


# =============================================================================
# Data Classes
# =============================================================================

@dataclass
class ColumnAnnotation:
    """Semantic annotation for a column."""
    column_name: str
    semantic_type: SemanticType
    is_pii: bool = False
    is_sensitive: bool = False
    validation_rules: List[str] = field(default_factory=list)
    format_hint: str = ""
    description: str = ""
    source: str = "inferred"  # inferred, odata, manual


@dataclass
class EntityAnnotation:
    """Semantic annotation for an entity/table."""
    entity_name: str
    columns: List[ColumnAnnotation] = field(default_factory=list)
    relationships: List[Dict[str, str]] = field(default_factory=list)
    description: str = ""


# =============================================================================
# Validation Rules
# =============================================================================

# Validation rules for each semantic type
VALIDATION_RULES: Dict[SemanticType, List[str]] = {
    SemanticType.EMAIL: [
        "format_email",
        "max_length_254",
        "not_null_if_required",
    ],
    SemanticType.PHONE: [
        "format_phone",
        "min_length_7",
        "max_length_20",
    ],
    SemanticType.URL: [
        "format_url",
        "max_length_2048",
    ],
    SemanticType.PERSON_NAME: [
        "not_empty",
        "max_length_100",
        "no_special_chars",
    ],
    SemanticType.ADDRESS: [
        "not_empty",
        "max_length_256",
    ],
    SemanticType.POSTAL_CODE: [
        "format_postal",
        "max_length_20",
    ],
    SemanticType.CURRENCY: [
        "format_currency_code",
        "length_3",
        "uppercase",
    ],
    SemanticType.AMOUNT: [
        "numeric",
        "non_negative",
        "precision_check",
    ],
    SemanticType.PERCENTAGE: [
        "numeric",
        "range_0_100",
    ],
    SemanticType.DATE: [
        "format_date",
        "valid_date",
    ],
    SemanticType.DATETIME: [
        "format_datetime",
        "valid_datetime",
    ],
    SemanticType.TIMESTAMP: [
        "format_timestamp",
        "not_future_if_created",
    ],
    SemanticType.UUID: [
        "format_uuid",
        "length_36",
    ],
    SemanticType.ID: [
        "not_null",
        "unique",
    ],
}


# =============================================================================
# OData Vocabulary Client
# =============================================================================

class ODataVocabularyClient:
    """
    Client for OData vocabulary MCP server.
    
    Fetches semantic annotations from the odata-vocabularies MCP server
    and provides methods to annotate columns and tables.
    """
    
    def __init__(self):
        self.mcp_endpoint = os.environ.get(
            "CONTEXT_MCP_URL",
            os.environ.get("DATA_CLEANING_CONTEXT_MCP_ENDPOINT", "http://localhost:9150/mcp")
        ).rstrip("/")
        if not self.mcp_endpoint.endswith("/mcp"):
            self.mcp_endpoint = f"{self.mcp_endpoint}/mcp"
        
        self._cache: Dict[str, Any] = {}
        self._available = None
    
    def available(self) -> bool:
        """Check if OData vocabulary MCP is available."""
        if self._available is not None:
            return self._available
        
        try:
            req = urllib.request.Request(
                self.mcp_endpoint.replace("/mcp", "/health"),
                method="GET",
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                self._available = resp.status == 200
        except Exception:
            self._available = False
        
        return self._available
    
    def _call_mcp(self, tool_name: str, arguments: dict) -> Optional[dict]:
        """Call MCP tool and return result."""
        payload = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": tool_name,
                "arguments": arguments,
            },
        }
        
        try:
            req = urllib.request.Request(
                self.mcp_endpoint,
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                result = json.loads(resp.read().decode())
                if "error" in result:
                    logger.error(f"MCP error: {result['error']}")
                    return None
                
                # Unwrap MCP content
                content = result.get("result", {}).get("content", [])
                if content and isinstance(content, list):
                    text = content[0].get("text", "{}")
                    return json.loads(text)
                return result.get("result")
        except Exception as e:
            logger.debug(f"OData MCP call failed: {e}")
            return None
    
    def get_vocabulary(self, vocabulary_name: str) -> Optional[dict]:
        """
        Fetch a vocabulary definition from the MCP server.
        
        Args:
            vocabulary_name: Name of the vocabulary (e.g., "Common", "Communication")
            
        Returns:
            Vocabulary definition or None if unavailable
        """
        cache_key = f"vocab:{vocabulary_name}"
        if cache_key in self._cache:
            return self._cache[cache_key]
        
        result = self._call_mcp("vocabulary_lookup", {"vocabulary": vocabulary_name})
        if result:
            self._cache[cache_key] = result
        return result
    
    def get_schema_annotations(self, schema_name: str) -> Optional[dict]:
        """
        Fetch annotations for a schema from the MCP server.
        
        Args:
            schema_name: Name of the schema/namespace
            
        Returns:
            Schema annotations or None if unavailable
        """
        return self._call_mcp("schema_annotation", {"schema": schema_name})
    
    def get_entity_relationships(self, entity_name: str) -> List[dict]:
        """
        Fetch relationships for an entity from the MCP server.
        
        Args:
            entity_name: Name of the entity
            
        Returns:
            List of relationships
        """
        result = self._call_mcp("entity_relationship", {"entity": entity_name})
        if result and isinstance(result.get("relationships"), list):
            return result["relationships"]
        return []


# =============================================================================
# Annotation Engine
# =============================================================================

class AnnotationEngine:
    """
    Engine for annotating columns and tables with semantic types.
    
    Combines:
    1. OData vocabulary lookups (if available)
    2. Column name pattern matching
    3. Data type inference
    """
    
    def __init__(self, vocab_client: ODataVocabularyClient = None):
        self.vocab_client = vocab_client or ODataVocabularyClient()
    
    def infer_semantic_type(self, column_name: str, data_type: str = "") -> SemanticType:
        """
        Infer semantic type from column name and data type.
        
        Args:
            column_name: Name of the column
            data_type: SQL data type (optional)
            
        Returns:
            Inferred SemanticType
        """
        # Normalize column name
        normalized = column_name.lower().replace("-", "_").replace(" ", "_")
        
        # Check exact matches first
        if normalized in COLUMN_NAME_PATTERNS:
            return COLUMN_NAME_PATTERNS[normalized]
        
        # Check partial matches
        for pattern, sem_type in COLUMN_NAME_PATTERNS.items():
            if pattern in normalized:
                return sem_type
        
        # Infer from data type
        if data_type:
            data_type_lower = data_type.lower()
            if "date" in data_type_lower:
                return SemanticType.DATE
            if "time" in data_type_lower:
                return SemanticType.TIMESTAMP if "stamp" in data_type_lower else SemanticType.TIME
            if "decimal" in data_type_lower or "numeric" in data_type_lower:
                return SemanticType.AMOUNT
            if "uuid" in data_type_lower or "guid" in data_type_lower:
                return SemanticType.UUID
        
        return SemanticType.UNKNOWN
    
    def annotate_column(
        self,
        column_name: str,
        data_type: str = "",
        odata_annotation: dict = None
    ) -> ColumnAnnotation:
        """
        Create a full annotation for a column.
        
        Args:
            column_name: Name of the column
            data_type: SQL data type
            odata_annotation: Optional OData annotation from vocabulary
            
        Returns:
            ColumnAnnotation with semantic type, PII flag, validation rules
        """
        # Get semantic type from OData annotation or infer
        if odata_annotation and "semanticType" in odata_annotation:
            try:
                sem_type = SemanticType(odata_annotation["semanticType"])
                source = "odata"
            except ValueError:
                sem_type = self.infer_semantic_type(column_name, data_type)
                source = "inferred"
        else:
            sem_type = self.infer_semantic_type(column_name, data_type)
            source = "inferred"
        
        # Determine PII and sensitivity flags
        is_pii = sem_type in PII_TYPES
        is_sensitive = sem_type in SENSITIVE_TYPES or is_pii
        
        # Get validation rules
        validation_rules = VALIDATION_RULES.get(sem_type, []).copy()
        
        # Add OData-specific rules
        if odata_annotation:
            if odata_annotation.get("nullable") is False:
                validation_rules.append("not_null")
            if max_length := odata_annotation.get("maxLength"):
                validation_rules.append(f"max_length_{max_length}")
        
        return ColumnAnnotation(
            column_name=column_name,
            semantic_type=sem_type,
            is_pii=is_pii,
            is_sensitive=is_sensitive,
            validation_rules=validation_rules,
            format_hint=odata_annotation.get("format", "") if odata_annotation else "",
            description=odata_annotation.get("description", "") if odata_annotation else "",
            source=source,
        )
    
    def annotate_entity(
        self,
        entity_name: str,
        columns: List[Dict[str, str]],
        fetch_relationships: bool = True
    ) -> EntityAnnotation:
        """
        Annotate an entire entity/table.
        
        Args:
            entity_name: Name of the entity/table
            columns: List of column definitions [{name, type}]
            fetch_relationships: Whether to fetch FK relationships
            
        Returns:
            EntityAnnotation with all column annotations
        """
        # Try to fetch OData annotations
        odata_annotations = {}
        if self.vocab_client.available():
            schema_annot = self.vocab_client.get_schema_annotations(entity_name)
            if schema_annot and "columns" in schema_annot:
                odata_annotations = {
                    c["name"]: c for c in schema_annot["columns"]
                    if isinstance(c, dict) and "name" in c
                }
        
        # Annotate each column
        column_annotations = []
        for col in columns:
            col_name = col.get("name", "")
            col_type = col.get("type", "")
            odata_annot = odata_annotations.get(col_name)
            
            annotation = self.annotate_column(col_name, col_type, odata_annot)
            column_annotations.append(annotation)
        
        # Fetch relationships if requested
        relationships = []
        if fetch_relationships and self.vocab_client.available():
            relationships = self.vocab_client.get_entity_relationships(entity_name)
        
        return EntityAnnotation(
            entity_name=entity_name,
            columns=column_annotations,
            relationships=relationships,
        )
    
    def get_pii_columns(self, entity: EntityAnnotation) -> List[str]:
        """Get list of PII column names from entity annotation."""
        return [col.column_name for col in entity.columns if col.is_pii]
    
    def get_validation_rules_for_entity(
        self,
        entity: EntityAnnotation
    ) -> Dict[str, List[str]]:
        """Get validation rules grouped by column."""
        return {
            col.column_name: col.validation_rules
            for col in entity.columns
            if col.validation_rules
        }


# =============================================================================
# Singleton Instances
# =============================================================================

_vocab_client: Optional[ODataVocabularyClient] = None
_annotation_engine: Optional[AnnotationEngine] = None


def get_vocab_client() -> ODataVocabularyClient:
    """Get or create the global vocabulary client instance."""
    global _vocab_client
    if _vocab_client is None:
        _vocab_client = ODataVocabularyClient()
    return _vocab_client


def get_annotation_engine() -> AnnotationEngine:
    """Get or create the global annotation engine instance."""
    global _annotation_engine
    if _annotation_engine is None:
        _annotation_engine = AnnotationEngine(get_vocab_client())
    return _annotation_engine


# =============================================================================
# Convenience Functions
# =============================================================================

def annotate_table(
    table_name: str,
    columns: List[Dict[str, str]]
) -> EntityAnnotation:
    """
    Annotate a table with semantic types.
    
    Example:
        >>> annotation = annotate_table("Users", [
        ...     {"name": "Id", "type": "INTEGER"},
        ...     {"name": "Email", "type": "VARCHAR"},
        ...     {"name": "FirstName", "type": "VARCHAR"},
        ... ])
        >>> annotation.columns[1].is_pii  # True (email)
    """
    return get_annotation_engine().annotate_entity(table_name, columns)


def get_pii_columns_for_table(
    table_name: str,
    columns: List[Dict[str, str]]
) -> List[str]:
    """
    Get list of PII columns for a table.
    
    Example:
        >>> pii_cols = get_pii_columns_for_table("Users", [
        ...     {"name": "Id", "type": "INTEGER"},
        ...     {"name": "Email", "type": "VARCHAR"},
        ... ])
        >>> pii_cols  # ['Email']
    """
    entity = annotate_table(table_name, columns)
    return get_annotation_engine().get_pii_columns(entity)


def infer_column_type(column_name: str, data_type: str = "") -> dict:
    """
    Infer semantic type for a single column.
    
    Returns:
        Dict with semantic_type, is_pii, validation_rules
    """
    annotation = get_annotation_engine().annotate_column(column_name, data_type)
    return {
        "column_name": annotation.column_name,
        "semantic_type": annotation.semantic_type.value,
        "is_pii": annotation.is_pii,
        "is_sensitive": annotation.is_sensitive,
        "validation_rules": annotation.validation_rules,
    }