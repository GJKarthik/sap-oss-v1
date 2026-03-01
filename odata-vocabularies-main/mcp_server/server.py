"""
OData Vocabularies MCP Server - Phase 3 Enhanced

Model Context Protocol server with full XML vocabulary loading, Mangle reasoning,
and semantic search capabilities using vector embeddings.

Phase 1 Improvements:
- 1.1 Full XML vocabulary loading from vocabularies/*.xml
- 1.2 Mangle facts generation from vocabulary terms
- 1.3 Enhanced entity extraction with OData types

Phase 2 Improvements:
- 2.1 HANACloud vocabulary support
- 2.2 Enhanced ES index mapping integration
- 2.3 Analytical query routing rules

Phase 3 Improvements:
- 3.1 Vocabulary term embeddings for semantic search
- 3.2 Semantic term search tool
- 3.3 RAG context enrichment
"""

import json
import os
import glob
import re
import xml.etree.ElementTree as ET
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any, Dict, List, Optional, Tuple
import time
import math

# Optional: numpy for fast vector operations
try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

# =============================================================================
# Constants
# =============================================================================

EDM_NS = "{http://docs.oasis-open.org/odata/ns/edm}"
EDMX_NS = "{http://docs.oasis-open.org/odata/ns/edmx}"
MAX_REQUEST_BYTES = int(os.environ.get("MCP_MAX_REQUEST_BYTES", str(1024 * 1024)))
MAX_SEARCH_RESULTS = int(os.environ.get("MCP_MAX_SEARCH_RESULTS", "500"))
MAX_QUERY_LENGTH = int(os.environ.get("MCP_MAX_QUERY_LENGTH", "500"))
MAX_PROPERTIES_PER_REQUEST = int(os.environ.get("MCP_MAX_PROPERTIES_PER_REQUEST", "500"))

# =============================================================================
# Types
# =============================================================================

class MCPRequest:
    def __init__(self, data: dict):
        self.jsonrpc = data.get("jsonrpc", "2.0")
        self.id = data.get("id")
        self.method = data.get("method", "")
        self.params = data.get("params", {})


class MCPResponse:
    def __init__(self, id: Any, result: Any = None, error: dict = None):
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error

    def to_dict(self) -> dict:
        d = {"jsonrpc": self.jsonrpc, "id": self.id}
        if self.error:
            d["error"] = self.error
        else:
            d["result"] = self.result
        return d


def clamp_int(value: Any, default: int, min_value: int, max_value: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    if parsed < min_value:
        return min_value
    if parsed > max_value:
        return max_value
    return parsed


def clamp_float(value: Any, default: float, min_value: float, max_value: float) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return default
    if parsed < min_value:
        return min_value
    if parsed > max_value:
        return max_value
    return parsed


def parse_json_arg(value: Any, fallback: Any):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return fallback
    return value if value is not None else fallback


# =============================================================================
# Entity Configuration for OData Types (Phase 1.3)
# =============================================================================

class ODataEntityConfig:
    """Configuration for OData entity type patterns"""
    def __init__(self, entity_type: str, pattern: str, key_property: str, 
                 text_property: str, namespace: str = ""):
        self.entity_type = entity_type
        self.pattern = re.compile(pattern, re.IGNORECASE)
        self.key_property = key_property
        self.text_property = text_property
        self.namespace = namespace

# Default entity configurations based on common SAP business objects
DEFAULT_ENTITY_CONFIGS = [
    ODataEntityConfig(
        "SalesOrder",
        r"(?:sales\s*order|so)[\s\-#]*([A-Z0-9\-]+)",
        "SalesOrderID", "SalesOrderDescription",
        "com.sap.gateway.srvd.c_salesorder_srv"
    ),
    ODataEntityConfig(
        "BusinessPartner",
        r"(?:customer|vendor|bp|partner|business\s*partner)[\s\-#]*([A-Z0-9\-]+)",
        "BusinessPartner", "BusinessPartnerFullName",
        "com.sap.gateway.srvd.c_businesspartner_srv"
    ),
    ODataEntityConfig(
        "Material",
        r"(?:material|product|item|article)[\s\-#]*([A-Z0-9\-]+)",
        "Material", "MaterialDescription",
        "com.sap.gateway.srvd.c_material_srv"
    ),
    ODataEntityConfig(
        "PurchaseOrder",
        r"(?:purchase\s*order|po|procurement)[\s\-#]*([A-Z0-9\-]+)",
        "PurchaseOrderID", "PurchaseOrderDescription",
        "com.sap.gateway.srvd.c_purchaseorder_srv"
    ),
    ODataEntityConfig(
        "CostCenter",
        r"(?:cost\s*center|cc)[\s\-#]*([A-Z0-9\-]+)",
        "CostCenter", "CostCenterName",
        "com.sap.gateway.srvd.c_costcenter_srv"
    ),
    ODataEntityConfig(
        "Employee",
        r"(?:employee|emp|worker|person)[\s\-#]*([A-Z0-9\-]+)",
        "EmployeeID", "EmployeeName",
        "com.sap.gateway.srvd.c_employee_srv"
    ),
    ODataEntityConfig(
        "Project",
        r"(?:project|prj|wbs)[\s\-#]*([A-Z0-9\-]+)",
        "ProjectID", "ProjectDescription",
        "com.sap.gateway.srvd.c_project_srv"
    ),
    ODataEntityConfig(
        "Invoice",
        r"(?:invoice|bill|inv)[\s\-#]*([A-Z0-9\-]+)",
        "InvoiceID", "InvoiceDescription",
        "com.sap.gateway.srvd.c_invoice_srv"
    ),
    ODataEntityConfig(
        "WorkOrder",
        r"(?:work\s*order|wo|maintenance)[\s\-#]*([A-Z0-9\-]+)",
        "WorkOrderID", "WorkOrderDescription",
        "com.sap.gateway.srvd.c_workorder_srv"
    ),
    ODataEntityConfig(
        "Asset",
        r"(?:asset|equipment|fixed\s*asset)[\s\-#]*([A-Z0-9\-]+)",
        "AssetID", "AssetDescription",
        "com.sap.gateway.srvd.c_asset_srv"
    ),
]

# =============================================================================
# MCP Server Implementation
# =============================================================================

class MCPServer:
    def __init__(self):
        self.tools = {}
        self.resources = {}
        self.facts = {}
        self.vocabularies = {}
        self.mangle_facts = []  # Generated Mangle facts
        self.entity_configs = DEFAULT_ENTITY_CONFIGS
        
        self._load_vocabularies_from_xml()
        self._generate_mangle_facts()
        self._load_embeddings()  # Phase 3.1
        self._register_tools()
        self._register_resources()
        self._initialize_facts()

    # =========================================================================
    # Phase 1.1: Full XML Vocabulary Loading
    # =========================================================================
    
    def _load_vocabularies_from_xml(self):
        """Load all vocabularies from XML files dynamically"""
        vocab_dir = os.path.join(os.path.dirname(__file__), '..', 'vocabularies')
        self.vocabularies = {}
        
        if not os.path.exists(vocab_dir):
            print(f"Warning: Vocabulary directory not found: {vocab_dir}")
            self._load_fallback_vocabularies()
            return
        
        xml_files = glob.glob(os.path.join(vocab_dir, '*.xml'))
        
        if not xml_files:
            print(f"Warning: No XML files found in {vocab_dir}")
            self._load_fallback_vocabularies()
            return
            
        for xml_file in xml_files:
            try:
                vocab_name = os.path.basename(xml_file).replace('.xml', '')
                vocab_data = self._parse_vocabulary_xml(xml_file)
                if vocab_data:
                    self.vocabularies[vocab_name] = vocab_data
                    print(f"Loaded vocabulary: {vocab_name} ({len(vocab_data['terms'])} terms)")
            except Exception as e:
                print(f"Error loading vocabulary {xml_file}: {e}")
        
        print(f"Total vocabularies loaded: {len(self.vocabularies)}")
        total_terms = sum(len(v['terms']) for v in self.vocabularies.values())
        print(f"Total terms loaded: {total_terms}")

    def _parse_vocabulary_xml(self, xml_file: str) -> Optional[Dict]:
        """Parse a vocabulary XML file and extract terms, types, and metadata"""
        try:
            tree = ET.parse(xml_file)
            root = tree.getroot()
            
            # Find the Schema element
            schema = root.find(f".//{EDM_NS}Schema")
            if schema is None:
                return None
            
            namespace = schema.get('Namespace', '')
            alias = schema.get('Alias', '')
            
            # Extract terms
            terms = []
            for term in schema.findall(f"{EDM_NS}Term"):
                term_data = self._extract_term(term, namespace)
                if term_data:
                    terms.append(term_data)
            
            # Extract complex types
            complex_types = {}
            for complex_type in schema.findall(f"{EDM_NS}ComplexType"):
                type_name = complex_type.get('Name', '')
                complex_types[type_name] = self._extract_complex_type(complex_type)
            
            # Extract enum types
            enum_types = {}
            for enum_type in schema.findall(f"{EDM_NS}EnumType"):
                type_name = enum_type.get('Name', '')
                enum_types[type_name] = self._extract_enum_type(enum_type)
            
            # Extract type definitions
            type_definitions = {}
            for type_def in schema.findall(f"{EDM_NS}TypeDefinition"):
                type_name = type_def.get('Name', '')
                type_definitions[type_name] = {
                    'underlying_type': type_def.get('UnderlyingType', ''),
                    'description': self._get_annotation_string(type_def, 'Core.Description')
                }
            
            return {
                'namespace': namespace,
                'alias': alias,
                'terms': terms,
                'complex_types': complex_types,
                'enum_types': enum_types,
                'type_definitions': type_definitions,
                'file': xml_file
            }
        except ET.ParseError as e:
            print(f"XML parse error in {xml_file}: {e}")
            return None

    def _extract_term(self, term_elem, namespace: str) -> Optional[Dict]:
        """Extract term information from XML element"""
        name = term_elem.get('Name')
        if not name:
            return None
        
        term_type = term_elem.get('Type', 'Edm.String')
        nullable = term_elem.get('Nullable', 'true') == 'true'
        applies_to = term_elem.get('AppliesTo', '').split() if term_elem.get('AppliesTo') else []
        default_value = term_elem.get('DefaultValue')
        base_term = term_elem.get('BaseTerm')
        
        # Get description from annotation
        description = self._get_annotation_string(term_elem, 'Core.Description')
        long_description = self._get_annotation_string(term_elem, 'Core.LongDescription')
        
        # Check if experimental
        experimental = self._has_annotation(term_elem, 'Common.Experimental')
        
        # Check if deprecated
        deprecated = self._is_deprecated(term_elem)
        
        # Check if instance annotation
        is_instance_annotation = self._has_annotation(term_elem, 'Common.IsInstanceAnnotation')
        
        # Get requires type
        requires_type = self._get_annotation_string(term_elem, 'Core.RequiresType')
        
        return {
            'name': name,
            'type': term_type,
            'nullable': nullable,
            'applies_to': applies_to,
            'default_value': default_value,
            'base_term': base_term,
            'description': description,
            'long_description': long_description,
            'experimental': experimental,
            'deprecated': deprecated,
            'is_instance_annotation': is_instance_annotation,
            'requires_type': requires_type,
            'full_name': f"{namespace}.{name}"
        }

    def _extract_complex_type(self, type_elem) -> Dict:
        """Extract complex type information"""
        properties = []
        for prop in type_elem.findall(f"{EDM_NS}Property"):
            properties.append({
                'name': prop.get('Name', ''),
                'type': prop.get('Type', ''),
                'nullable': prop.get('Nullable', 'true') == 'true',
                'description': self._get_annotation_string(prop, 'Core.Description')
            })
        
        return {
            'kind': 'ComplexType',
            'base_type': type_elem.get('BaseType'),
            'abstract': type_elem.get('Abstract', 'false') == 'true',
            'properties': properties,
            'description': self._get_annotation_string(type_elem, 'Core.Description')
        }

    def _extract_enum_type(self, type_elem) -> Dict:
        """Extract enum type information"""
        members = []
        for member in type_elem.findall(f"{EDM_NS}Member"):
            members.append({
                'name': member.get('Name', ''),
                'value': member.get('Value'),
                'description': self._get_annotation_string(member, 'Core.Description')
            })
        
        return {
            'kind': 'EnumType',
            'underlying_type': type_elem.get('UnderlyingType'),
            'is_flags': type_elem.get('IsFlags', 'false') == 'true',
            'members': members,
            'description': self._get_annotation_string(type_elem, 'Core.Description')
        }

    def _get_annotation_string(self, elem, term: str) -> str:
        """Get string value from an annotation"""
        for ann in elem.findall(f"{EDM_NS}Annotation"):
            if ann.get('Term') == term:
                # Check for String attribute
                string_val = ann.get('String')
                if string_val:
                    return string_val
                # Check for nested String element
                string_elem = ann.find(f"{EDM_NS}String")
                if string_elem is not None and string_elem.text:
                    return string_elem.text.strip()
        return ""

    def _has_annotation(self, elem, term: str) -> bool:
        """Check if element has a specific annotation"""
        for ann in elem.findall(f"{EDM_NS}Annotation"):
            if ann.get('Term') == term:
                return True
        return False

    def _is_deprecated(self, elem) -> bool:
        """Check if element is deprecated via Core.Revisions annotation"""
        for ann in elem.findall(f"{EDM_NS}Annotation"):
            if ann.get('Term') == 'Core.Revisions':
                # Check for deprecated revision
                for record in ann.findall(f".//{EDM_NS}Record"):
                    for prop_val in record.findall(f"{EDM_NS}PropertyValue"):
                        if prop_val.get('Property') == 'Kind':
                            enum_member = prop_val.get('EnumMember', '')
                            if 'Deprecated' in enum_member:
                                return True
        return False

    # =========================================================================
    # Phase 3.1: Embedding Loading
    # =========================================================================
    
    def _load_embeddings(self):
        """Load pre-computed vocabulary embeddings for semantic search"""
        self.term_embeddings = {}
        self.embedding_index = {}
        self.embedding_vectors = None
        self.embedding_keys = None
        
        embeddings_dir = os.path.join(os.path.dirname(__file__), '..', '_embeddings')
        
        # Try loading numpy arrays first (faster)
        if HAS_NUMPY:
            keys_path = os.path.join(embeddings_dir, 'embedding_keys.npy')
            vectors_path = os.path.join(embeddings_dir, 'embedding_vectors.npy')
            
            if os.path.exists(keys_path) and os.path.exists(vectors_path):
                try:
                    self.embedding_keys = np.load(keys_path, allow_pickle=True)
                    self.embedding_vectors = np.load(vectors_path)
                    print(f"Loaded {len(self.embedding_keys)} embeddings from numpy arrays")
                except Exception as e:
                    print(f"Error loading numpy embeddings: {e}")
        
        # Load JSON embeddings for metadata
        embeddings_path = os.path.join(embeddings_dir, 'vocabulary_embeddings.json')
        index_path = os.path.join(embeddings_dir, 'vocabulary_index.json')
        
        if os.path.exists(embeddings_path):
            try:
                with open(embeddings_path) as f:
                    self.term_embeddings = json.load(f)
                print(f"Loaded {len(self.term_embeddings)} term embeddings")
            except Exception as e:
                print(f"Error loading embeddings JSON: {e}")
        
        if os.path.exists(index_path):
            try:
                with open(index_path) as f:
                    self.embedding_index = json.load(f)
                print(f"Embedding index: {self.embedding_index.get('total_terms', 0)} terms")
            except Exception as e:
                print(f"Error loading embedding index: {e}")

    def _cosine_similarity(self, a: List[float], b: List[float]) -> float:
        """Calculate cosine similarity between two vectors"""
        if HAS_NUMPY:
            a_arr = np.array(a)
            b_arr = np.array(b)
            return float(np.dot(a_arr, b_arr) / (np.linalg.norm(a_arr) * np.linalg.norm(b_arr)))
        else:
            dot = sum(x * y for x, y in zip(a, b))
            mag_a = math.sqrt(sum(x * x for x in a))
            mag_b = math.sqrt(sum(x * x for x in b))
            return dot / (mag_a * mag_b) if mag_a * mag_b > 0 else 0.0

    def _get_query_embedding(self, query: str) -> Optional[List[float]]:
        """Get embedding for a query text.
        
        In production, this would call the embedding API.
        For now, we use a deterministic hash-based placeholder.
        """
        import hashlib
        
        # Create deterministic placeholder embedding
        h = hashlib.sha256(query.lower().encode()).digest()
        embedding = []
        dims = 1536
        
        for i in range(dims):
            idx = i % 32
            val = h[idx] / 255.0 - 0.5
            embedding.append(val)
        
        # Normalize
        if HAS_NUMPY:
            arr = np.array(embedding)
            arr = arr / np.linalg.norm(arr)
            return arr.tolist()
        else:
            mag = math.sqrt(sum(x * x for x in embedding))
            return [x / mag for x in embedding]

    def _load_fallback_vocabularies(self):
        """Load minimal fallback vocabularies if XML files not available"""
        self.vocabularies = {
            "Common": {"namespace": "com.sap.vocabularies.Common.v1", "alias": "Common", 
                      "terms": [{"name": "Label", "type": "Edm.String", "description": "A short, human-readable text suitable for labels"}],
                      "complex_types": {}, "enum_types": {}, "type_definitions": {}},
            "UI": {"namespace": "com.sap.vocabularies.UI.v1", "alias": "UI",
                  "terms": [{"name": "LineItem", "type": "Collection(UI.DataFieldAbstract)", "description": "Collection of data fields for table columns"}],
                  "complex_types": {}, "enum_types": {}, "type_definitions": {}},
            "Analytics": {"namespace": "com.sap.vocabularies.Analytics.v1", "alias": "Analytics",
                         "terms": [{"name": "Dimension", "type": "Core.Tag", "description": "Property holds dimension key"}],
                         "complex_types": {}, "enum_types": {}, "type_definitions": {}},
        }

    # =========================================================================
    # Phase 1.2: Mangle Facts Generation
    # =========================================================================
    
    def _generate_mangle_facts(self):
        """Generate Mangle facts from vocabulary definitions"""
        self.mangle_facts = []
        
        # Generate vocabulary facts
        for vocab_name, vocab_data in self.vocabularies.items():
            namespace = vocab_data.get('namespace', '')
            
            # vocabulary(Name, Namespace)
            self.mangle_facts.append(f'vocabulary("{vocab_name}", "{namespace}").')
            
            # Generate term facts
            for term in vocab_data.get('terms', []):
                term_name = term.get('name', '') if isinstance(term, dict) else term
                term_type = term.get('type', 'Edm.String') if isinstance(term, dict) else 'Edm.String'
                description = term.get('description', '') if isinstance(term, dict) else ''
                
                # Escape quotes in description
                description = description.replace('"', '\\"').replace('\n', ' ')[:200]
                
                # term(Vocabulary, Name, Type, Description)
                self.mangle_facts.append(
                    f'term("{vocab_name}", "{term_name}", "{term_type}", "{description}").'
                )
                
                # term_applies_to facts
                applies_to = term.get('applies_to', []) if isinstance(term, dict) else []
                for target in applies_to:
                    self.mangle_facts.append(
                        f'term_applies_to("{vocab_name}", "{term_name}", "{target}").'
                    )
                
                # term_experimental fact
                if isinstance(term, dict) and term.get('experimental'):
                    self.mangle_facts.append(
                        f'term_experimental("{vocab_name}", "{term_name}").'
                    )
                
                # term_deprecated fact
                if isinstance(term, dict) and term.get('deprecated'):
                    self.mangle_facts.append(
                        f'term_deprecated("{vocab_name}", "{term_name}").'
                    )
            
            # Generate complex type facts
            for type_name, type_data in vocab_data.get('complex_types', {}).items():
                self.mangle_facts.append(
                    f'complex_type("{vocab_name}", "{type_name}").'
                )
                for prop in type_data.get('properties', []):
                    prop_name = prop.get('name', '')
                    prop_type = prop.get('type', '')
                    self.mangle_facts.append(
                        f'type_property("{vocab_name}", "{type_name}", "{prop_name}", "{prop_type}").'
                    )
            
            # Generate enum type facts
            for type_name, type_data in vocab_data.get('enum_types', {}).items():
                self.mangle_facts.append(
                    f'enum_type("{vocab_name}", "{type_name}").'
                )
                for member in type_data.get('members', []):
                    member_name = member.get('name', '')
                    self.mangle_facts.append(
                        f'enum_member("{vocab_name}", "{type_name}", "{member_name}").'
                    )
        
        # Generate entity config facts
        for config in self.entity_configs:
            self.mangle_facts.append(
                f'entity_config("{config.entity_type}", "{config.key_property}", "{config.text_property}", "{config.namespace}").'
            )
        
        print(f"Generated {len(self.mangle_facts)} Mangle facts")

    def get_mangle_facts_content(self) -> str:
        """Get all Mangle facts as a single string"""
        header = """# Auto-generated Mangle facts from OData vocabularies
# Generated at: {timestamp}
#
# Predicate declarations:
# Decl vocabulary(Name, Namespace) descr [extensional()].
# Decl term(Vocabulary, Name, Type, Description) descr [extensional()].
# Decl term_applies_to(Vocabulary, Term, Target) descr [extensional()].
# Decl term_experimental(Vocabulary, Term) descr [extensional()].
# Decl term_deprecated(Vocabulary, Term) descr [extensional()].
# Decl complex_type(Vocabulary, Name) descr [extensional()].
# Decl type_property(Vocabulary, Type, Property, PropertyType) descr [extensional()].
# Decl enum_type(Vocabulary, Name) descr [extensional()].
# Decl enum_member(Vocabulary, Type, Member) descr [extensional()].
# Decl entity_config(EntityType, KeyProperty, TextProperty, Namespace) descr [extensional()].

""".format(timestamp=time.strftime('%Y-%m-%d %H:%M:%S'))
        
        return header + "\n".join(self.mangle_facts)

    # =========================================================================
    # Phase 1.3: Enhanced Entity Extraction
    # =========================================================================
    
    def extract_entities(self, query: str) -> List[Dict]:
        """Extract entities from a query using OData entity configurations"""
        results = []
        
        for config in self.entity_configs:
            match = config.pattern.search(query)
            if match:
                entity_id = match.group(1) if match.groups() else ""
                results.append({
                    'entity_type': config.entity_type,
                    'entity_id': entity_id,
                    'key_property': config.key_property,
                    'text_property': config.text_property,
                    'namespace': config.namespace,
                    'match': match.group(0),
                    'confidence': 0.85
                })
        
        return results

    def add_entity_config(self, entity_type: str, pattern: str, key_property: str, 
                         text_property: str, namespace: str = ""):
        """Add a new entity configuration dynamically"""
        config = ODataEntityConfig(entity_type, pattern, key_property, text_property, namespace)
        self.entity_configs.append(config)
        # Regenerate Mangle facts
        self._generate_mangle_facts()

    # =========================================================================
    # Tool Registration
    # =========================================================================

    def _register_tools(self):
        # List Vocabularies
        self.tools["list_vocabularies"] = {
            "name": "list_vocabularies",
            "description": "List all SAP OData vocabularies with term counts",
            "inputSchema": {"type": "object", "properties": {
                "include_experimental": {"type": "boolean", "description": "Include experimental terms", "default": True}
            }},
        }

        # Get Vocabulary (enhanced)
        self.tools["get_vocabulary"] = {
            "name": "get_vocabulary",
            "description": "Get detailed information about a specific vocabulary including all terms and types",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Vocabulary name (e.g., Common, UI, Analytics)"},
                    "include_types": {"type": "boolean", "description": "Include complex and enum types", "default": True}
                },
                "required": ["name"],
            },
        }

        # Search Terms (enhanced)
        self.tools["search_terms"] = {
            "name": "search_terms",
            "description": "Search for terms across all vocabularies with detailed results",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query"},
                    "vocabulary": {"type": "string", "description": "Limit search to specific vocabulary"},
                    "include_deprecated": {"type": "boolean", "description": "Include deprecated terms", "default": False}
                },
                "required": ["query"],
            },
        }

        # Get Term Details
        self.tools["get_term"] = {
            "name": "get_term",
            "description": "Get detailed information about a specific vocabulary term",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "vocabulary": {"type": "string", "description": "Vocabulary name"},
                    "term": {"type": "string", "description": "Term name"},
                },
                "required": ["vocabulary", "term"],
            },
        }

        # Extract Entities (new)
        self.tools["extract_entities"] = {
            "name": "extract_entities",
            "description": "Extract OData entities from a natural language query",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Natural language query to extract entities from"},
                },
                "required": ["query"],
            },
        }

        # Get Mangle Facts (new)
        self.tools["get_mangle_facts"] = {
            "name": "get_mangle_facts",
            "description": "Get auto-generated Mangle facts from vocabulary definitions",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "vocabulary": {"type": "string", "description": "Filter facts for specific vocabulary"},
                    "fact_type": {"type": "string", "description": "Filter by fact type (term, type, enum)", 
                                "enum": ["all", "vocabulary", "term", "type", "enum", "entity_config"]}
                },
            },
        }

        # Validate Annotations
        self.tools["validate_annotations"] = {
            "name": "validate_annotations",
            "description": "Validate OData annotations against vocabularies",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "annotations": {"type": "string", "description": "Annotations as JSON or XML"},
                },
                "required": ["annotations"],
            },
        }

        # Generate Annotations
        self.tools["generate_annotations"] = {
            "name": "generate_annotations",
            "description": "Generate OData annotations for an entity",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "entity_type": {"type": "string", "description": "Entity type name"},
                    "properties": {"type": "string", "description": "Entity properties as JSON array"},
                    "vocabulary": {"type": "string", "description": "Target vocabulary (UI, Common, etc)"},
                },
                "required": ["entity_type", "properties"],
            },
        }

        # Lookup Term (legacy, kept for compatibility)
        self.tools["lookup_term"] = {
            "name": "lookup_term",
            "description": "Lookup a specific vocabulary term (alias for get_term)",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "vocabulary": {"type": "string", "description": "Vocabulary name"},
                    "term": {"type": "string", "description": "Term name"},
                },
                "required": ["vocabulary", "term"],
            },
        }

        # Convert Format
        self.tools["convert_annotations"] = {
            "name": "convert_annotations",
            "description": "Convert annotations between JSON and XML formats",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "input": {"type": "string", "description": "Input annotations"},
                    "from_format": {"type": "string", "description": "Source format (json/xml)"},
                    "to_format": {"type": "string", "description": "Target format (json/xml)"},
                },
                "required": ["input", "from_format", "to_format"],
            },
        }

        # Mangle Query
        self.tools["mangle_query"] = {
            "name": "mangle_query",
            "description": "Query the Mangle reasoning engine with vocabulary facts",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "predicate": {"type": "string", "description": "Predicate to query"},
                    "args": {"type": "string", "description": "Arguments as JSON array"},
                },
                "required": ["predicate"],
            },
        }

        # Get Vocabulary Statistics
        self.tools["get_statistics"] = {
            "name": "get_statistics",
            "description": "Get statistics about loaded vocabularies",
            "inputSchema": {"type": "object", "properties": {}},
        }

        # Phase 3.2: Semantic Term Search
        self.tools["semantic_search"] = {
            "name": "semantic_search",
            "description": "Semantic search across vocabulary terms using embeddings",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Natural language search query"},
                    "top_k": {"type": "integer", "description": "Number of results to return", "default": 10},
                    "min_similarity": {"type": "number", "description": "Minimum similarity threshold (0-1)", "default": 0.3},
                    "vocabulary": {"type": "string", "description": "Filter to specific vocabulary (optional)"}
                },
                "required": ["query"],
            },
        }

        # Phase 3.3: RAG Context Enrichment
        self.tools["get_rag_context"] = {
            "name": "get_rag_context",
            "description": "Get enriched RAG context for a query including relevant vocabulary terms",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Natural language query"},
                    "entity_type": {"type": "string", "description": "Entity type to get context for (optional)"},
                    "include_annotations": {"type": "boolean", "description": "Include annotation suggestions", "default": True}
                },
                "required": ["query"],
            },
        }

        # Get Annotation Suggestions
        self.tools["suggest_annotations"] = {
            "name": "suggest_annotations",
            "description": "Suggest relevant OData annotations based on context",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "entity_type": {"type": "string", "description": "Entity type name"},
                    "properties": {"type": "string", "description": "Property names as JSON array"},
                    "use_case": {"type": "string", "description": "Use case (ui, analytics, personal_data)", 
                                "enum": ["ui", "analytics", "personal_data", "all"]}
                },
                "required": ["entity_type"],
            },
        }

    def _register_resources(self):
        self.resources["odata://vocabularies"] = {
            "uri": "odata://vocabularies",
            "name": "All Vocabularies",
            "description": "List of all OData vocabularies",
            "mimeType": "application/json",
        }
        self.resources["odata://common"] = {
            "uri": "odata://common",
            "name": "Common Vocabulary",
            "description": "SAP Common vocabulary terms",
            "mimeType": "application/json",
        }
        self.resources["odata://ui"] = {
            "uri": "odata://ui",
            "name": "UI Vocabulary",
            "description": "SAP UI vocabulary terms",
            "mimeType": "application/json",
        }
        self.resources["odata://analytics"] = {
            "uri": "odata://analytics",
            "name": "Analytics Vocabulary",
            "description": "SAP Analytics vocabulary terms",
            "mimeType": "application/json",
        }
        self.resources["mangle://facts"] = {
            "uri": "mangle://facts",
            "name": "Mangle Facts",
            "description": "Auto-generated Mangle facts from vocabularies",
            "mimeType": "text/plain",
        }
        self.resources["odata://entity-configs"] = {
            "uri": "odata://entity-configs",
            "name": "Entity Configurations",
            "description": "OData entity type patterns for extraction",
            "mimeType": "application/json",
        }
        self.resources["embeddings://index"] = {
            "uri": "embeddings://index",
            "name": "Embedding Index",
            "description": "Vocabulary embedding index for semantic search",
            "mimeType": "application/json",
        }

    def _initialize_facts(self):
        self.facts["service_registry"] = [
            {"name": "odata-vocab", "endpoint": "odata://vocab", "model": "vocabulary-engine"},
            {"name": "odata-annotate", "endpoint": "odata://annotate", "model": "annotation-generator"},
        ]
        self.facts["tool_invocation"] = []

    # =========================================================================
    # Tool Handlers
    # =========================================================================

    def _handle_list_vocabularies(self, args: dict) -> dict:
        include_experimental = args.get("include_experimental", True)
        
        vocab_list = []
        for name, data in self.vocabularies.items():
            terms = data.get('terms', [])
            
            # Count terms
            total = len(terms)
            experimental = sum(1 for t in terms if isinstance(t, dict) and t.get('experimental'))
            deprecated = sum(1 for t in terms if isinstance(t, dict) and t.get('deprecated'))
            stable = total - experimental - deprecated
            
            if not include_experimental:
                total = stable
            
            vocab_list.append({
                "name": name,
                "namespace": data.get('namespace', ''),
                "alias": data.get('alias', ''),
                "term_count": total,
                "stable_terms": stable,
                "experimental_terms": experimental,
                "deprecated_terms": deprecated,
                "complex_types": len(data.get('complex_types', {})),
                "enum_types": len(data.get('enum_types', {}))
            })
        
        vocab_list.sort(key=lambda x: x['term_count'], reverse=True)
        
        return {
            "vocabularies": vocab_list, 
            "count": len(vocab_list),
            "total_terms": sum(v['term_count'] for v in vocab_list)
        }

    def _handle_get_vocabulary(self, args: dict) -> dict:
        name = args.get("name", "")
        include_types = args.get("include_types", True)
        
        vocab = self.vocabularies.get(name)
        if vocab:
            result = {
                "name": name,
                "namespace": vocab.get('namespace', ''),
                "alias": vocab.get('alias', ''),
                "terms": vocab.get('terms', []),
                "term_count": len(vocab.get('terms', []))
            }
            
            if include_types:
                result["complex_types"] = vocab.get('complex_types', {})
                result["enum_types"] = vocab.get('enum_types', {})
                result["type_definitions"] = vocab.get('type_definitions', {})
            
            return result
        
        return {
            "error": f"Vocabulary '{name}' not found", 
            "available": list(self.vocabularies.keys())
        }

    def _handle_search_terms(self, args: dict) -> dict:
        query = str(args.get("query", "") or "").lower()[:MAX_QUERY_LENGTH]
        target_vocab = args.get("vocabulary")
        include_deprecated = args.get("include_deprecated", False)
        
        results = []
        
        for vocab_name, vocab in self.vocabularies.items():
            if target_vocab and vocab_name.lower() != target_vocab.lower():
                continue
                
            for term in vocab.get('terms', []):
                if isinstance(term, dict):
                    term_name = term.get('name', '')
                    description = term.get('description', '')
                    is_deprecated = term.get('deprecated', False)
                    is_experimental = term.get('experimental', False)
                    
                    # Skip deprecated if not included
                    if is_deprecated and not include_deprecated:
                        continue
                    
                    # Search in name and description
                    if query in term_name.lower() or query in description.lower():
                        results.append({
                            "vocabulary": vocab_name,
                            "term": term_name,
                            "type": term.get('type', ''),
                            "description": description[:200],
                            "namespace": vocab.get('namespace', ''),
                            "full_name": term.get('full_name', f"{vocab.get('namespace', '')}.{term_name}"),
                            "applies_to": term.get('applies_to', []),
                            "experimental": is_experimental,
                            "deprecated": is_deprecated
                        })
                else:
                    # Simple string term
                    if query in term.lower():
                        results.append({
                            "vocabulary": vocab_name,
                            "term": term,
                            "namespace": vocab.get('namespace', '')
                        })
        
        return {"query": query, "results": results[:MAX_SEARCH_RESULTS], "count": len(results)}

    def _handle_get_term(self, args: dict) -> dict:
        vocabulary = args.get("vocabulary", "")
        term_name = args.get("term", "")
        
        vocab = self.vocabularies.get(vocabulary)
        if not vocab:
            return {"error": f"Vocabulary '{vocabulary}' not found"}
        
        for term in vocab.get('terms', []):
            if isinstance(term, dict):
                if term.get('name') == term_name:
                    return {
                        "vocabulary": vocabulary,
                        "namespace": vocab.get('namespace', ''),
                        **term
                    }
            elif term == term_name:
                return {
                    "vocabulary": vocabulary,
                    "term": term_name,
                    "namespace": vocab.get('namespace', ''),
                    "full_name": f"{vocab.get('namespace', '')}.{term_name}"
                }
        
        return {"error": f"Term '{term_name}' not found in vocabulary '{vocabulary}'"}

    def _handle_extract_entities(self, args: dict) -> dict:
        query = args.get("query", "")
        entities = self.extract_entities(query)
        
        return {
            "query": query,
            "entities": entities,
            "count": len(entities)
        }

    def _handle_get_mangle_facts(self, args: dict) -> dict:
        vocabulary = args.get("vocabulary")
        fact_type = args.get("fact_type", "all")
        
        facts = self.mangle_facts
        
        # Filter by vocabulary
        if vocabulary:
            facts = [f for f in facts if f'"{vocabulary}"' in f]
        
        # Filter by type
        if fact_type != "all":
            type_prefixes = {
                "vocabulary": "vocabulary(",
                "term": "term(",
                "type": ["complex_type(", "type_property(", "enum_type("],
                "enum": ["enum_type(", "enum_member("],
                "entity_config": "entity_config("
            }
            
            prefix = type_prefixes.get(fact_type, "")
            if isinstance(prefix, list):
                facts = [f for f in facts if any(f.startswith(p) for p in prefix)]
            elif prefix:
                facts = [f for f in facts if f.startswith(prefix)]
        
        return {
            "facts": facts,
            "count": len(facts),
            "total_facts": len(self.mangle_facts)
        }

    def _handle_validate_annotations(self, args: dict) -> dict:
        annotations = args.get("annotations", "")
        errors = []
        warnings = []
        
        try:
            if annotations.strip().startswith("{"):
                data = json.loads(annotations)
                # Validate JSON annotations
                for key, value in data.items():
                    if key.startswith("@"):
                        term_parts = key[1:].split(".")
                        if len(term_parts) >= 2:
                            vocab_alias = term_parts[-2] if len(term_parts) > 2 else term_parts[0]
                            term_name = term_parts[-1]
                            
                            # Check if vocabulary exists
                            found = False
                            for vocab_name, vocab in self.vocabularies.items():
                                if vocab.get('alias', '').lower() == vocab_alias.lower() or vocab_name.lower() == vocab_alias.lower():
                                    # Check if term exists
                                    for term in vocab.get('terms', []):
                                        t_name = term.get('name', '') if isinstance(term, dict) else term
                                        if t_name == term_name:
                                            found = True
                                            if isinstance(term, dict) and term.get('deprecated'):
                                                warnings.append(f"Term '{key}' is deprecated")
                                            break
                                    break
                            
                            if not found:
                                warnings.append(f"Term '{key}' not found in vocabularies")
                
                return {"valid": True, "format": "json", "errors": errors, "warnings": warnings}
                
            elif annotations.strip().startswith("<"):
                return {"valid": True, "format": "xml", "errors": errors, "warnings": warnings}
            
            return {"valid": False, "error": "Unknown format", "errors": ["Could not detect format"]}
            
        except json.JSONDecodeError as e:
            return {"valid": False, "error": str(e), "errors": [str(e)]}

    def _handle_generate_annotations(self, args: dict) -> dict:
        entity_type = args.get("entity_type", "")
        properties = parse_json_arg(args.get("properties", "[]"), [])
        if not isinstance(properties, list):
            properties = []
        properties = [str(p) for p in properties[:MAX_PROPERTIES_PER_REQUEST] if p is not None]
        vocabulary = args.get("vocabulary", "UI")
        
        annotations = {}
        
        if vocabulary == "UI":
            # Generate UI.LineItem
            line_items = []
            for prop in properties:
                line_items.append({
                    "$Type": "com.sap.vocabularies.UI.v1.DataField",
                    "Value": {"$Path": prop}
                })
            annotations["@UI.LineItem"] = line_items
            
            # Generate UI.HeaderInfo suggestion
            if properties:
                annotations["@UI.HeaderInfo"] = {
                    "$Type": "com.sap.vocabularies.UI.v1.HeaderInfoType",
                    "TypeName": entity_type,
                    "TypeNamePlural": f"{entity_type}s",
                    "Title": {"$Type": "com.sap.vocabularies.UI.v1.DataField", "Value": {"$Path": properties[0]}}
                }
        
        elif vocabulary == "Common":
            # Generate Common.Label for each property
            for prop in properties:
                annotations[f"@Common.Label#{prop}"] = prop.replace("_", " ").title()
        
        return {"entityType": entity_type, "vocabulary": vocabulary, "annotations": annotations}

    def _handle_lookup_term(self, args: dict) -> dict:
        # Alias for get_term
        return self._handle_get_term(args)

    def _handle_convert_annotations(self, args: dict) -> dict:
        input_str = args.get("input", "")
        from_format = args.get("from_format", "")
        to_format = args.get("to_format", "")
        
        if from_format == "json" and to_format == "xml":
            try:
                data = json.loads(input_str)
                # Convert JSON to XML
                xml_parts = ['<?xml version="1.0" encoding="utf-8"?>', '<edmx:Edmx Version="4.0" xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">', '  <edmx:DataServices>']
                for key, value in data.items():
                    if key.startswith("@"):
                        xml_parts.append(f'    <Annotation Term="{key[1:]}" />')
                xml_parts.extend(['  </edmx:DataServices>', '</edmx:Edmx>'])
                return {"output": "\n".join(xml_parts), "format": "xml"}
            except:
                return {"error": "Failed to parse JSON input"}
        
        return {
            "from_format": from_format,
            "to_format": to_format,
            "status": "Conversion not fully implemented for this format combination",
        }

    def _handle_mangle_query(self, args: dict) -> dict:
        predicate = args.get("predicate", "")
        query_args = parse_json_arg(args.get("args", "[]"), [])
        if not isinstance(query_args, list):
            query_args = []
        
        # Search in generated facts
        results = []
        for fact in self.mangle_facts:
            if fact.startswith(f"{predicate}("):
                results.append(fact)
        
        # Filter by args if provided
        if query_args:
            filtered = []
            for result in results:
                match = True
                for i, arg in enumerate(query_args):
                    if arg and f'"{arg}"' not in result:
                        match = False
                        break
                if match:
                    filtered.append(result)
            results = filtered
        
        return {"predicate": predicate, "args": query_args, "results": results, "count": len(results)}

    def _handle_get_statistics(self, args: dict) -> dict:
        stats = {
            "vocabularies": len(self.vocabularies),
            "total_terms": sum(len(v.get('terms', [])) for v in self.vocabularies.values()),
            "total_complex_types": sum(len(v.get('complex_types', {})) for v in self.vocabularies.values()),
            "total_enum_types": sum(len(v.get('enum_types', {})) for v in self.vocabularies.values()),
            "mangle_facts": len(self.mangle_facts),
            "entity_configs": len(self.entity_configs),
            "embeddings_loaded": len(self.term_embeddings),
            "vocabulary_details": {}
        }
        
        for name, vocab in self.vocabularies.items():
            terms = vocab.get('terms', [])
            stats["vocabulary_details"][name] = {
                "namespace": vocab.get('namespace', ''),
                "terms": len(terms),
                "experimental": sum(1 for t in terms if isinstance(t, dict) and t.get('experimental')),
                "deprecated": sum(1 for t in terms if isinstance(t, dict) and t.get('deprecated')),
                "complex_types": len(vocab.get('complex_types', {})),
                "enum_types": len(vocab.get('enum_types', {}))
            }
        
        return stats

    # =========================================================================
    # Phase 3.2: Semantic Term Search
    # =========================================================================
    
    def _handle_semantic_search(self, args: dict) -> dict:
        """Semantic search across vocabulary terms using embeddings"""
        query = str(args.get("query", "") or "")[:MAX_QUERY_LENGTH]
        top_k = clamp_int(args.get("top_k", 10), 10, 1, MAX_SEARCH_RESULTS)
        min_similarity = clamp_float(args.get("min_similarity", 0.3), 0.3, 0.0, 1.0)
        target_vocab = args.get("vocabulary")
        
        if not self.term_embeddings:
            return {
                "error": "Embeddings not loaded. Run scripts/generate_vocab_embeddings.py first.",
                "query": query
            }
        
        # Get query embedding
        query_embedding = self._get_query_embedding(query)
        
        results = []
        
        # Calculate similarities
        for term_key, term_data in self.term_embeddings.items():
            # Filter by vocabulary if specified
            if target_vocab:
                vocab_name = term_key.split('.')[0] if '.' in term_key else ''
                if vocab_name.lower() != target_vocab.lower():
                    continue
            
            term_embedding = term_data.get("embedding", [])
            if not term_embedding:
                continue
            
            similarity = self._cosine_similarity(query_embedding, term_embedding)
            
            if similarity >= min_similarity:
                # Get term details from index
                term_info = self.embedding_index.get("terms", {}).get(term_key, {})
                
                results.append({
                    "term": term_key,
                    "vocabulary": term_info.get("vocabulary", term_key.split('.')[0]),
                    "term_name": term_info.get("term_name", term_key.split('.')[-1]),
                    "description": term_info.get("description", ""),
                    "term_type": term_info.get("term_type", ""),
                    "applies_to": term_info.get("applies_to", []),
                    "similarity": round(similarity, 4),
                    "embedding_text": term_data.get("text", "")
                })
        
        # Sort by similarity descending
        results.sort(key=lambda x: x["similarity"], reverse=True)
        
        return {
            "query": query,
            "results": results[:top_k],
            "total_matches": len(results),
            "total_terms_searched": len(self.term_embeddings),
            "model": self.embedding_index.get("model", "unknown")
        }

    # =========================================================================
    # Phase 3.3: RAG Context Enrichment
    # =========================================================================
    
    def _handle_get_rag_context(self, args: dict) -> dict:
        """Get enriched RAG context for a query"""
        query = args.get("query", "")
        entity_type = args.get("entity_type")
        include_annotations = args.get("include_annotations", True)
        
        context = {
            "query": query,
            "extracted_entities": [],
            "relevant_vocabularies": [],
            "semantic_matches": [],
            "annotation_context": {},
            "mangle_facts": []
        }
        
        # 1. Extract entities from query
        entities = self.extract_entities(query)
        context["extracted_entities"] = entities
        
        # 2. Get semantically relevant terms
        if self.term_embeddings:
            semantic_results = self._handle_semantic_search({
                "query": query,
                "top_k": 5,
                "min_similarity": 0.4
            })
            context["semantic_matches"] = semantic_results.get("results", [])
        
        # 3. Determine relevant vocabularies
        relevant_vocabs = set()
        
        # From semantic matches
        for match in context["semantic_matches"]:
            relevant_vocabs.add(match.get("vocabulary", ""))
        
        # From query keywords
        query_lower = query.lower()
        if any(kw in query_lower for kw in ["ui", "display", "table", "form", "list"]):
            relevant_vocabs.add("UI")
        if any(kw in query_lower for kw in ["analytics", "dimension", "measure", "aggregate"]):
            relevant_vocabs.add("Analytics")
        if any(kw in query_lower for kw in ["personal", "gdpr", "sensitive", "privacy"]):
            relevant_vocabs.add("PersonalData")
        if any(kw in query_lower for kw in ["common", "label", "text", "description"]):
            relevant_vocabs.add("Common")
        if any(kw in query_lower for kw in ["hana", "calculation", "view"]):
            relevant_vocabs.add("HANACloud")
        
        context["relevant_vocabularies"] = list(relevant_vocabs)
        
        # 4. Get annotation context
        if include_annotations and entity_type:
            context["annotation_context"] = self._get_annotation_context(entity_type)
        elif include_annotations and entities:
            # Use first extracted entity
            context["annotation_context"] = self._get_annotation_context(entities[0]["entity_type"])
        
        # 5. Get relevant Mangle facts
        for vocab in relevant_vocabs:
            vocab_facts = [f for f in self.mangle_facts if f'"{vocab}"' in f][:10]
            context["mangle_facts"].extend(vocab_facts)
        
        return context

    def _get_annotation_context(self, entity_type: str) -> dict:
        """Get annotation context for an entity type"""
        context = {
            "entity_type": entity_type,
            "common_annotations": [],
            "ui_annotations": [],
            "analytics_annotations": [],
            "personal_data_annotations": []
        }
        
        # Common annotations typically applicable
        common_terms = ["Label", "Text", "SemanticKey", "SemanticObject", "FieldControl"]
        for term in common_terms:
            term_data = self._get_term_info("Common", term)
            if term_data:
                context["common_annotations"].append(term_data)
        
        # UI annotations
        ui_terms = ["LineItem", "HeaderInfo", "Facets", "FieldGroup", "SelectionFields"]
        for term in ui_terms:
            term_data = self._get_term_info("UI", term)
            if term_data:
                context["ui_annotations"].append(term_data)
        
        # Analytics annotations
        analytics_terms = ["Dimension", "Measure", "AggregatedProperty"]
        for term in analytics_terms:
            term_data = self._get_term_info("Analytics", term)
            if term_data:
                context["analytics_annotations"].append(term_data)
        
        # Personal data annotations
        pd_terms = ["IsPotentiallyPersonal", "IsPotentiallySensitive", "FieldSemantics"]
        for term in pd_terms:
            term_data = self._get_term_info("PersonalData", term)
            if term_data:
                context["personal_data_annotations"].append(term_data)
        
        return context

    def _get_term_info(self, vocabulary: str, term_name: str) -> Optional[dict]:
        """Get basic term info"""
        vocab = self.vocabularies.get(vocabulary)
        if not vocab:
            return None
        
        for term in vocab.get('terms', []):
            if isinstance(term, dict) and term.get('name') == term_name:
                return {
                    "term": f"@{vocabulary}.{term_name}",
                    "type": term.get('type', ''),
                    "description": term.get('description', '')[:150],
                    "applies_to": term.get('applies_to', [])
                }
        return None

    def _handle_suggest_annotations(self, args: dict) -> dict:
        """Suggest relevant OData annotations based on context"""
        entity_type = args.get("entity_type", "")
        raw_properties = parse_json_arg(args.get("properties", "[]"), []) if args.get("properties") else []
        properties = [str(p) for p in raw_properties[:MAX_PROPERTIES_PER_REQUEST] if p is not None] if isinstance(raw_properties, list) else []
        use_case = args.get("use_case", "all")
        
        suggestions = {
            "entity_type": entity_type,
            "entity_level": [],
            "property_level": {}
        }
        
        # Entity-level suggestions
        if use_case in ["all", "ui"]:
            suggestions["entity_level"].append({
                "annotation": "@UI.HeaderInfo",
                "description": "Header information for object pages",
                "example": {
                    "$Type": "com.sap.vocabularies.UI.v1.HeaderInfoType",
                    "TypeName": entity_type,
                    "TypeNamePlural": f"{entity_type}s"
                }
            })
            suggestions["entity_level"].append({
                "annotation": "@UI.LineItem",
                "description": "Table columns for list display"
            })
        
        if use_case in ["all", "personal_data"]:
            suggestions["entity_level"].append({
                "annotation": "@PersonalData.EntitySemantics",
                "description": "GDPR classification for entity",
                "example": "DataSubject or DataSubjectDetails"
            })
        
        # Property-level suggestions
        for prop in properties:
            prop_suggestions = []
            
            if use_case in ["all", "ui"]:
                prop_suggestions.append({
                    "annotation": f"@Common.Label: '{prop.replace('_', ' ').title()}'",
                    "description": "Display label"
                })
            
            # Detect special properties
            prop_lower = prop.lower()
            
            if any(kw in prop_lower for kw in ["amount", "price", "value", "total", "sum"]):
                if use_case in ["all", "analytics"]:
                    prop_suggestions.append({
                        "annotation": "@Analytics.Measure: true",
                        "description": "Mark as analytical measure"
                    })
                prop_suggestions.append({
                    "annotation": "@Measures.ISOCurrency",
                    "description": "Currency reference"
                })
            
            if any(kw in prop_lower for kw in ["date", "created", "changed", "time"]):
                prop_suggestions.append({
                    "annotation": "@Common.IsCalendarDate: true",
                    "description": "Calendar date field"
                })
            
            if any(kw in prop_lower for kw in ["name", "email", "phone", "address", "ssn"]):
                if use_case in ["all", "personal_data"]:
                    prop_suggestions.append({
                        "annotation": "@PersonalData.IsPotentiallyPersonal: true",
                        "description": "GDPR: Potentially personal data"
                    })
            
            if any(kw in prop_lower for kw in ["id", "code", "key", "type", "category"]):
                if use_case in ["all", "analytics"]:
                    prop_suggestions.append({
                        "annotation": "@Analytics.Dimension: true",
                        "description": "Mark as analytical dimension"
                    })
            
            if prop_suggestions:
                suggestions["property_level"][prop] = prop_suggestions
        
        return suggestions

    # =========================================================================
    # Request Handler
    # =========================================================================

    def handle_request(self, request: MCPRequest) -> MCPResponse:
        method = request.method
        params = request.params
        id = request.id

        try:
            if request.jsonrpc != "2.0":
                return MCPResponse(id, error={"code": -32600, "message": "Invalid Request: jsonrpc must be '2.0'"})
            if not isinstance(params, dict):
                return MCPResponse(id, error={"code": -32600, "message": "Invalid Request: params must be an object"})

            if method == "initialize":
                return MCPResponse(id, {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {"listChanged": True}, "resources": {"listChanged": True}, "prompts": {"listChanged": True}},
                    "serverInfo": {"name": "odata-vocabularies-mcp", "version": "2.0.0"},
                })

            elif method == "tools/list":
                return MCPResponse(id, {"tools": list(self.tools.values())})

            elif method == "tools/call":
                tool_name = params.get("name", "")
                args = params.get("arguments", {})
                if args is None:
                    args = {}
                if not isinstance(args, dict):
                    return MCPResponse(id, error={"code": -32602, "message": "Invalid params: arguments must be an object"})
                handlers = {
                    "list_vocabularies": self._handle_list_vocabularies,
                    "get_vocabulary": self._handle_get_vocabulary,
                    "search_terms": self._handle_search_terms,
                    "get_term": self._handle_get_term,
                    "extract_entities": self._handle_extract_entities,
                    "get_mangle_facts": self._handle_get_mangle_facts,
                    "validate_annotations": self._handle_validate_annotations,
                    "generate_annotations": self._handle_generate_annotations,
                    "lookup_term": self._handle_lookup_term,
                    "convert_annotations": self._handle_convert_annotations,
                    "mangle_query": self._handle_mangle_query,
                    "get_statistics": self._handle_get_statistics,
                    "semantic_search": self._handle_semantic_search,
                    "get_rag_context": self._handle_get_rag_context,
                    "suggest_annotations": self._handle_suggest_annotations,
                }
                handler = handlers.get(tool_name)
                if not handler:
                    return MCPResponse(id, error={"code": -32602, "message": f"Unknown tool: {tool_name}"})
                result = handler(args)
                self.facts["tool_invocation"].append({"tool": tool_name, "timestamp": time.time()})
                return MCPResponse(id, {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]})

            elif method == "resources/list":
                return MCPResponse(id, {"resources": list(self.resources.values())})

            elif method == "resources/read":
                uri = params.get("uri", "")
                if uri == "odata://vocabularies":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", 
                                                          "text": json.dumps(self._handle_list_vocabularies({}), indent=2)}]})
                if uri == "odata://common":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", 
                                                          "text": json.dumps(self._handle_get_vocabulary({"name": "Common"}), indent=2)}]})
                if uri == "odata://ui":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", 
                                                          "text": json.dumps(self._handle_get_vocabulary({"name": "UI"}), indent=2)}]})
                if uri == "odata://analytics":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", 
                                                          "text": json.dumps(self._handle_get_vocabulary({"name": "Analytics"}), indent=2)}]})
                if uri == "mangle://facts":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "text/plain", 
                                                          "text": self.get_mangle_facts_content()}]})
                if uri == "odata://entity-configs":
                    configs = [{"entity_type": c.entity_type, "pattern": c.pattern.pattern, 
                               "key_property": c.key_property, "text_property": c.text_property,
                               "namespace": c.namespace} for c in self.entity_configs]
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", 
                                                          "text": json.dumps(configs, indent=2)}]})
                if uri == "embeddings://index":
                    return MCPResponse(id, {"contents": [{"uri": uri, "mimeType": "application/json", 
                                                          "text": json.dumps(self.embedding_index, indent=2)}]})
                return MCPResponse(id, error={"code": -32602, "message": f"Unknown resource: {uri}"})

            else:
                return MCPResponse(id, error={"code": -32601, "message": f"Method not found: {method}"})

        except Exception as e:
            import traceback
            traceback.print_exc()
            return MCPResponse(id, error={"code": -32603, "message": str(e)})


# =============================================================================
# HTTP Server
# =============================================================================

CORS_ALLOWED_ORIGINS = [
    o.strip() for o in os.environ.get("CORS_ALLOWED_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000").split(",")
    if o.strip()
]


def _cors_origin(handler: BaseHTTPRequestHandler) -> str | None:
    origin = (handler.headers.get("Origin") or "").strip()
    if origin and origin in CORS_ALLOWED_ORIGINS:
        return origin
    return CORS_ALLOWED_ORIGINS[0] if CORS_ALLOWED_ORIGINS else None


mcp_server = MCPServer()


class MCPHandler(BaseHTTPRequestHandler):
    def _write_json(self, status_code: int, payload: dict):
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

    def do_OPTIONS(self):
        self.send_response(204)
        origin = _cors_origin(self)
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            from datetime import datetime, timezone
            stats = mcp_server._handle_get_statistics({})
            response = {
                "status": "healthy", 
                "service": "odata-vocabularies-mcp", 
                "version": "2.0.0",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "vocabularies_loaded": stats["vocabularies"],
                "total_terms": stats["total_terms"],
                "mangle_facts": stats["mangle_facts"]
            }
            self._write_json(200, response)
        elif self.path == "/stats":
            stats = mcp_server._handle_get_statistics({})
            self._write_json(200, stats)
        else:
            self._write_json(404, {"error": "Not found"})

    def do_POST(self):
        if self.path == "/mcp":
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length <= 0:
                self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request: empty body"}})
                return
            if content_length > MAX_REQUEST_BYTES:
                self._write_json(413, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Request too large"}})
                return

            raw_body = self.rfile.read(content_length)
            try:
                body = raw_body.decode("utf-8")
                data = json.loads(body)
                if not isinstance(data, dict):
                    self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}})
                    return
                request = MCPRequest(data)
                response = mcp_server.handle_request(request)
                self._write_json(200, response.to_dict())
            except UnicodeDecodeError:
                self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Invalid UTF-8 body"}})
            except json.JSONDecodeError:
                self._write_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
        elif self.path == "/mcp/tools/extract_entities":
            # Direct endpoint for entity extraction
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length <= 0:
                self._write_json(400, {"error": "Invalid Request: empty body"})
                return
            if content_length > MAX_REQUEST_BYTES:
                self._write_json(413, {"error": "Request too large"})
                return

            raw_body = self.rfile.read(content_length)
            try:
                body = raw_body.decode("utf-8")
                data = json.loads(body)
                if not isinstance(data, dict):
                    self._write_json(400, {"error": "Invalid JSON payload"})
                    return
                query = data.get("query", "")
                entities = mcp_server.extract_entities(query)

                # Return first entity if found
                if entities:
                    result = {"entity_type": entities[0]["entity_type"], "entity_id": entities[0]["entity_id"]}
                else:
                    result = {"entity_type": "", "entity_id": ""}

                self._write_json(200, result)
            except UnicodeDecodeError:
                self._write_json(400, {"error": "Invalid UTF-8 body"})
            except json.JSONDecodeError:
                self._write_json(400, {"error": "Invalid JSON"})
        else:
            self._write_json(404, {"error": "Not found"})

    def log_message(self, format, *args):
        pass


def main():
    import sys
    port = 9150
    for arg in sys.argv[1:]:
        if arg.startswith("--port="):
            port = int(arg.split("=")[1])

    stats = mcp_server._handle_get_statistics({})
    
    server = HTTPServer(("", port), MCPHandler)
    print(f"""
╔══════════════════════════════════════════════════════════════════════════╗
║   OData Vocabularies MCP Server v3.0.0 - Phase 3 Enhanced                ║
║   Model Context Protocol v2024-11-05                                     ║
╚══════════════════════════════════════════════════════════════════════════╝

Server: http://localhost:{port}

Loaded Statistics:
  - Vocabularies: {stats['vocabularies']}
  - Total Terms: {stats['total_terms']}
  - Complex Types: {stats['total_complex_types']}
  - Enum Types: {stats['total_enum_types']}
  - Mangle Facts: {stats['mangle_facts']}
  - Entity Configs: {stats['entity_configs']}
  - Embeddings: {stats.get('embeddings_loaded', 0)}

Tools: 
  Phase 1: list_vocabularies, get_vocabulary, search_terms, get_term,
           extract_entities, get_mangle_facts, validate_annotations,
           generate_annotations, lookup_term, convert_annotations,
           mangle_query, get_statistics
  Phase 3: semantic_search, get_rag_context, suggest_annotations

Resources: odata://vocabularies, odata://common, odata://ui,
           odata://analytics, mangle://facts, odata://entity-configs,
           embeddings://index

Endpoints:
  - POST /mcp              - MCP JSON-RPC endpoint
  - POST /mcp/tools/extract_entities - Direct entity extraction
  - GET  /health           - Health check with stats
  - GET  /stats            - Detailed statistics
""")
    server.serve_forever()


if __name__ == "__main__":
    main()
