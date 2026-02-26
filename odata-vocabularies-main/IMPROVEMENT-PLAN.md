 # OData Vocabularies: Improvement Plan for Universal Dictionary

## Executive Summary

This document outlines concrete improvements to enhance the OData Vocabularies repository as the universal dictionary for data and HANA discovery, with specific focus on integration with the `mangle-query-service` platform.

---

## Phase 1: Immediate Improvements (Week 1-2)

### 1.1 Enhanced MCP Server with Full Vocabulary Loading

**Current Gap:** MCP server only loads a subset of vocabulary terms hardcoded in Python.

**Improvement:**

```python
# mcp_server/server.py - Enhanced vocabulary loading
import xml.etree.ElementTree as ET
import glob
import os

class MCPServer:
    def _load_vocabularies(self):
        """Load all vocabularies from XML files dynamically"""
        vocab_dir = os.path.join(os.path.dirname(__file__), '..', 'vocabularies')
        self.vocabularies = {}
        
        for xml_file in glob.glob(os.path.join(vocab_dir, '*.xml')):
            vocab_name = os.path.basename(xml_file).replace('.xml', '')
            tree = ET.parse(xml_file)
            root = tree.getroot()
            
            # Extract namespace
            namespace = root.get('Namespace', '')
            
            # Extract all terms
            terms = []
            for term in root.findall('.//{http://docs.oasis-open.org/odata/ns/edm}Term'):
                term_data = {
                    'name': term.get('Name'),
                    'type': term.get('Type'),
                    'description': self._get_description(term),
                    'applies_to': term.get('AppliesTo', '').split(),
                    'experimental': self._is_experimental(term)
                }
                terms.append(term_data)
            
            self.vocabularies[vocab_name] = {
                'namespace': namespace,
                'terms': terms,
                'types': self._extract_types(root),
                'file': xml_file
            }
    
    def _get_description(self, term):
        """Extract term description from annotations"""
        for ann in term.findall('.//{http://docs.oasis-open.org/odata/ns/edm}Annotation'):
            if ann.get('Term') == 'Core.Description':
                return ann.get('String', '')
        return ''
    
    def _is_experimental(self, term):
        """Check if term is marked experimental"""
        for ann in term.findall('.//{http://docs.oasis-open.org/odata/ns/edm}Annotation'):
            if 'Experimental' in ann.get('Term', ''):
                return True
        return False
    
    def _extract_types(self, root):
        """Extract ComplexType and EnumType definitions"""
        types = {}
        for complex_type in root.findall('.//{http://docs.oasis-open.org/odata/ns/edm}ComplexType'):
            types[complex_type.get('Name')] = {
                'kind': 'ComplexType',
                'properties': [p.get('Name') for p in complex_type.findall('.//{http://docs.oasis-open.org/odata/ns/edm}Property')]
            }
        for enum_type in root.findall('.//{http://docs.oasis-open.org/odata/ns/edm}EnumType'):
            types[enum_type.get('Name')] = {
                'kind': 'EnumType',
                'members': [m.get('Name') for m in enum_type.findall('.//{http://docs.oasis-open.org/odata/ns/edm}Member')]
            }
        return types
```

### 1.2 Add Mangle Facts for Vocabulary Terms

**Current Gap:** Mangle engine doesn't have direct access to vocabulary semantics.

**Improvement:** Create Mangle facts from vocabulary definitions.

```mangle
# mangle/domain/vocabularies.mg - Auto-generated from XML

# Vocabulary declarations
Decl vocabulary(Name, Namespace) descr [extensional()].
Decl term(Vocabulary, Name, Type, Description) descr [extensional()].
Decl term_applies_to(Vocabulary, Term, Target) descr [extensional()].
Decl term_experimental(Vocabulary, Term) descr [extensional()].

# Example facts (auto-generated from Common.xml)
vocabulary("Common", "com.sap.vocabularies.Common.v1").
term("Common", "Label", "String", "A short, human-readable text suitable for labels").
term("Common", "Text", "String?", "A descriptive text for values of the annotated property").
term("Common", "SemanticObject", "String?", "Name of the Semantic Object").
term("Common", "IsCurrency", "Tag", "Annotated property or parameter is a currency code").

term_applies_to("Common", "Label", "Property").
term_applies_to("Common", "Label", "Parameter").
term_applies_to("Common", "Text", "Property").

term("Analytics", "Dimension", "Tag", "Property holds the key of a dimension").
term("Analytics", "Measure", "Tag", "Property holds the numeric value of a measure").

# Inference rules for entity discovery
is_analytical_property(EntityType, Property) :-
    has_annotation(EntityType, Property, "Analytics", "Dimension").
is_analytical_property(EntityType, Property) :-
    has_annotation(EntityType, Property, "Analytics", "Measure").

is_personal_data(EntityType, Property) :-
    has_annotation(EntityType, Property, "PersonalData", "IsPotentiallyPersonal").
```

### 1.3 Enhanced Entity Extraction with OData Types

**Current Gap:** Entity patterns in mangle-query-service are hardcoded.

**Improvement:** Dynamic entity patterns from OData vocabulary.

```go
// internal/predicates/mcp_entities.go - Enhanced

type ODataEntityConfig struct {
    EntityType    string   `json:"entity_type"`
    Pattern       string   `json:"pattern"`
    KeyProperty   string   `json:"key_property"`
    TextProperty  string   `json:"text_property"`
    Namespace     string   `json:"namespace"`
}

var entityConfigs = []ODataEntityConfig{
    // Generated from OData service metadata + Common vocabulary
    {
        EntityType:   "SalesOrder",
        Pattern:      `(?i)(?:sales\s*order|so)[\s\-#]*([A-Z0-9\-]+)`,
        KeyProperty:  "SalesOrderID",
        TextProperty: "SalesOrderDescription",
        Namespace:    "com.sap.gateway.srvd.c_salesorder_srv",
    },
    {
        EntityType:   "BusinessPartner",
        Pattern:      `(?i)(?:customer|vendor|bp|partner)[\s\-#]*([A-Z0-9\-]+)`,
        KeyProperty:  "BusinessPartner",
        TextProperty: "BusinessPartnerFullName",
        Namespace:    "com.sap.gateway.srvd.c_businesspartner_srv",
    },
    {
        EntityType:   "Material",
        Pattern:      `(?i)(?:material|product|item)[\s\-#]*([A-Z0-9\-]+)`,
        KeyProperty:  "Material",
        TextProperty: "MaterialDescription",
        Namespace:    "com.sap.gateway.srvd.c_material_srv",
    },
}

func (p *MCPEntitiesPredicate) loadEntityConfigs() error {
    // Load from MCP server endpoint that reads OData service metadata
    resp, err := http.Get(p.MCPAddress + "/mcp/resources/odata://entity-configs")
    if err != nil {
        return err
    }
    defer resp.Body.Close()
    
    return json.NewDecoder(resp.Body).Decode(&entityConfigs)
}
```

---

## Phase 2: HANA Discovery Enhancements (Week 3-4)

### 2.1 HANA Calculation View Metadata Vocabulary

**Create new vocabulary extension for HANA-specific metadata:**

```xml
<!-- vocabularies/HANACloud.xml - New vocabulary -->
<?xml version="1.0" encoding="utf-8"?>
<edmx:Edmx xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx" Version="4.0">
  <edmx:Reference Uri="https://oasis-tcs.github.io/odata-vocabularies/vocabularies/Org.OData.Core.V1.xml">
    <edmx:Include Namespace="Org.OData.Core.V1" Alias="Core"/>
  </edmx:Reference>
  <edmx:DataServices>
    <Schema xmlns="http://docs.oasis-open.org/odata/ns/edm" 
            Namespace="com.sap.vocabularies.HANACloud.v1" Alias="HANACloud">
      
      <Term Name="CalculationView" Type="HANACloud.CalculationViewType" AppliesTo="EntitySet">
        <Annotation Term="Core.Description" String="Reference to HANA calculation view"/>
      </Term>
      
      <Term Name="ColumnMapping" Type="HANACloud.ColumnMappingType" AppliesTo="Property">
        <Annotation Term="Core.Description" String="Mapping to HANA column"/>
      </Term>
      
      <Term Name="InputParameter" Type="HANACloud.InputParameterType" AppliesTo="Parameter">
        <Annotation Term="Core.Description" String="HANA calculation view input parameter"/>
      </Term>
      
      <Term Name="HierarchyNode" Type="HANACloud.HierarchyNodeType" AppliesTo="EntityType">
        <Annotation Term="Core.Description" String="HANA hierarchy node configuration"/>
      </Term>
      
      <ComplexType Name="CalculationViewType">
        <Property Name="SchemaName" Type="Edm.String" Nullable="false"/>
        <Property Name="ViewName" Type="Edm.String" Nullable="false"/>
        <Property Name="PackagePath" Type="Edm.String"/>
        <Property Name="ViewType" Type="HANACloud.ViewTypeEnum"/>
      </ComplexType>
      
      <ComplexType Name="ColumnMappingType">
        <Property Name="HANAColumnName" Type="Edm.String" Nullable="false"/>
        <Property Name="HANADataType" Type="Edm.String"/>
        <Property Name="Precision" Type="Edm.Int32"/>
        <Property Name="Scale" Type="Edm.Int32"/>
      </ComplexType>
      
      <ComplexType Name="InputParameterType">
        <Property Name="ParameterName" Type="Edm.String" Nullable="false"/>
        <Property Name="DataType" Type="Edm.String"/>
        <Property Name="Mandatory" Type="Edm.Boolean"/>
        <Property Name="DefaultValue" Type="Edm.String"/>
      </ComplexType>
      
      <ComplexType Name="HierarchyNodeType">
        <Property Name="HierarchyName" Type="Edm.String" Nullable="false"/>
        <Property Name="NodeColumn" Type="Edm.String" Nullable="false"/>
        <Property Name="ParentColumn" Type="Edm.String" Nullable="false"/>
        <Property Name="LevelColumn" Type="Edm.String"/>
      </ComplexType>
      
      <EnumType Name="ViewTypeEnum">
        <Member Name="CalculationView" Value="0"/>
        <Member Name="AttributeView" Value="1"/>
        <Member Name="AnalyticView" Value="2"/>
        <Member Name="Table" Value="3"/>
        <Member Name="SQLView" Value="4"/>
      </EnumType>
      
    </Schema>
  </edmx:DataServices>
</edmx:Edmx>
```

### 2.2 ES Index Mapping with Full OData Semantics

**Enhanced Elasticsearch mapping that captures OData vocabulary annotations:**

```go
// internal/es/indices.go - Enhanced

const ODataEntityMapping = `{
    "mappings": {
        "properties": {
            "entity_type": {"type": "keyword"},
            "entity_namespace": {"type": "keyword"},
            "hana_key": {"type": "keyword"},
            
            "odata_metadata": {
                "type": "object",
                "properties": {
                    "namespace": {"type": "keyword"},
                    "entity_set": {"type": "keyword"},
                    "key_properties": {"type": "keyword"},
                    "is_analytical": {"type": "boolean"},
                    "has_hierarchy": {"type": "boolean"}
                }
            },
            
            "common_annotations": {
                "type": "object",
                "properties": {
                    "label": {"type": "text"},
                    "description": {"type": "text"},
                    "semantic_object": {"type": "keyword"},
                    "semantic_key": {"type": "keyword"}
                }
            },
            
            "analytics_annotations": {
                "type": "object",
                "properties": {
                    "dimensions": {"type": "keyword"},
                    "measures": {"type": "keyword"},
                    "hierarchy_qualifier": {"type": "keyword"}
                }
            },
            
            "personal_data": {
                "type": "object",
                "properties": {
                    "is_data_subject": {"type": "boolean"},
                    "data_subject_role": {"type": "keyword"},
                    "sensitive_fields": {"type": "keyword"}
                }
            },
            
            "fields": {"type": "object", "dynamic": true},
            "display_text": {"type": "text"},
            "display_text_embedding": {"type": "dense_vector", "dims": 1536, "similarity": "cosine"},
            
            "hana_metadata": {
                "type": "object",
                "properties": {
                    "schema": {"type": "keyword"},
                    "table_or_view": {"type": "keyword"},
                    "calculation_view": {"type": "keyword"}
                }
            },
            
            "last_synced_at": {"type": "date"},
            "hana_changed_at": {"type": "date"}
        }
    }
}`
```

### 2.3 Mangle Rules for Analytical Query Routing

**Enhanced routing rules that leverage Analytics vocabulary:**

```mangle
# rules/analytics_routing.mg - New file

# Analytical query detection
is_analytical_query(Query) :-
    classify_query(Query, "ANALYTICAL", Confidence),
    Confidence >= 60.

is_analytical_query(Query) :-
    contains_aggregation_keyword(Query).

contains_aggregation_keyword(Query) :-
    Query :> match("(?i)(total|sum|average|count|max|min|trend|compare)").

# Route to HANA for analytical queries
resolve_analytical(Query, Result, "hana_analytical", Score) :-
    is_analytical_query(Query),
    extract_analytical_context(Query, Dimensions, Measures),
    es_get_calculation_view(Dimensions, Measures, ViewName),
    hana_execute_analytical(ViewName, Query, Result),
    Score = 90.

# Dimension/measure extraction using vocabulary
extract_analytical_context(Query, Dimensions, Measures) :-
    extract_entities(Query, EntityType, _),
    get_analytics_annotations(EntityType, Dimensions, Measures).

# Fallback for non-HANA analytical
resolve_analytical(Query, Result, "es_aggregation", Score) :-
    is_analytical_query(Query),
    !hana_available,
    es_aggregate_query(Query, Result),
    Score = 70.
```

---

## Phase 3: Vector Embeddings & RAG (Week 5-6)

### 3.1 Vocabulary Term Embeddings

**Generate embeddings for vocabulary terms for semantic search:**

```python
# scripts/generate_vocab_embeddings.py

import json
import os
from openai import OpenAI
from pathlib import Path

def generate_vocabulary_embeddings():
    client = OpenAI()
    vocab_dir = Path("vocabularies")
    embeddings = {}
    
    for md_file in vocab_dir.glob("*.md"):
        vocab_name = md_file.stem
        content = md_file.read_text()
        
        # Parse terms from markdown
        terms = parse_markdown_terms(content)
        
        for term in terms:
            term_text = f"{vocab_name}.{term['name']}: {term['description']}"
            
            response = client.embeddings.create(
                input=term_text,
                model="text-embedding-3-small"
            )
            
            embeddings[f"{vocab_name}.{term['name']}"] = {
                "vocabulary": vocab_name,
                "term": term['name'],
                "description": term['description'],
                "embedding": response.data[0].embedding
            }
    
    # Save to JSON for MCP server
    with open("_embeddings/vocabulary_embeddings.json", "w") as f:
        json.dump(embeddings, f)
    
    return embeddings

def parse_markdown_terms(content: str) -> list:
    """Parse terms from vocabulary markdown"""
    terms = []
    # Parse markdown table format
    in_terms_section = False
    for line in content.split('\n'):
        if '## Terms' in line:
            in_terms_section = True
            continue
        if in_terms_section and line.startswith('['):
            # Extract term name and description
            parts = line.split('|')
            if len(parts) >= 3:
                name = parts[0].strip('[] ').split('](')[0]
                description = parts[2].strip()
                terms.append({'name': name, 'description': description})
    return terms
```

### 3.2 Semantic Term Search Tool

**Add semantic search capability to MCP server:**

```python
# mcp_server/server.py - Add semantic search tool

import numpy as np
from typing import List, Dict

class MCPServer:
    def __init__(self):
        # ... existing init ...
        self._load_embeddings()
    
    def _load_embeddings(self):
        """Load pre-computed vocabulary embeddings"""
        embeddings_path = os.path.join(
            os.path.dirname(__file__), '..', '_embeddings', 'vocabulary_embeddings.json'
        )
        if os.path.exists(embeddings_path):
            with open(embeddings_path) as f:
                self.term_embeddings = json.load(f)
        else:
            self.term_embeddings = {}
    
    def _handle_semantic_search(self, args: dict) -> dict:
        """Semantic search across vocabulary terms"""
        query = args.get("query", "")
        top_k = args.get("top_k", 10)
        
        # Get query embedding
        query_embedding = self._get_embedding(query)
        
        # Calculate similarities
        results = []
        for term_key, term_data in self.term_embeddings.items():
            similarity = self._cosine_similarity(
                query_embedding, 
                term_data["embedding"]
            )
            results.append({
                "term": term_key,
                "vocabulary": term_data["vocabulary"],
                "description": term_data["description"],
                "similarity": float(similarity)
            })
        
        # Sort by similarity
        results.sort(key=lambda x: x["similarity"], reverse=True)
        
        return {
            "query": query,
            "results": results[:top_k],
            "total_terms_searched": len(self.term_embeddings)
        }
    
    def _cosine_similarity(self, a: List[float], b: List[float]) -> float:
        a = np.array(a)
        b = np.array(b)
        return np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b))
```

### 3.3 RAG Context Enrichment

**Enhance RAG with vocabulary context:**

```mangle
# rules/rag_enrichment.mg

# Enrich RAG context with vocabulary semantics
enrich_rag_context(Query, EnrichedContext) :-
    es_hybrid_search(Query, RawDocs, _),
    extract_entities(Query, EntityType, _),
    get_vocabulary_context(EntityType, VocabContext),
    merge_contexts(RawDocs, VocabContext, EnrichedContext).

get_vocabulary_context(EntityType, Context) :-
    get_common_annotations(EntityType, CommonAnn),
    get_analytics_annotations(EntityType, AnalyticsAnn),
    get_personal_data_annotations(EntityType, PersonalAnn),
    Context = {
        "common": CommonAnn,
        "analytics": AnalyticsAnn,
        "personal_data": PersonalAnn
    }.

# Enhanced resolve with vocabulary context
resolve(Query, Answer, "rag_enriched", Score) :-
    is_knowledge(Query),
    enrich_rag_context(Query, EnrichedContext),
    rerank(Query, EnrichedContext, RankedDocs),
    llm_generate_with_vocab(Query, RankedDocs, Answer),
    Score = 85.
```

---

## Phase 4: Governance & Compliance (Week 7-8)

### 4.1 PersonalData Vocabulary Integration

**Automatic GDPR classification in entity extraction:**

```go
// internal/predicates/personal_data.go - New file

type PersonalDataClassifier struct {
    MCPAddress string
}

type PersonalDataResult struct {
    EntityType           string   `json:"entity_type"`
    IsDataSubject        bool     `json:"is_data_subject"`
    DataSubjectRole      string   `json:"data_subject_role"`
    PotentiallyPersonal  []string `json:"potentially_personal"`
    PotentiallySensitive []string `json:"potentially_sensitive"`
    EndOfBusinessDate    string   `json:"end_of_business_date"`
}

func (c *PersonalDataClassifier) ClassifyEntity(entityType string) (*PersonalDataResult, error) {
    // Call MCP to get PersonalData annotations
    resp, err := http.Get(fmt.Sprintf("%s/mcp/tools/get_personal_data_annotations?entity=%s", 
        c.MCPAddress, entityType))
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()
    
    var result PersonalDataResult
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, err
    }
    return &result, nil
}

func (c *PersonalDataClassifier) MaskSensitiveFields(data map[string]interface{}, 
    sensitiveFields []string) map[string]interface{} {
    masked := make(map[string]interface{})
    for k, v := range data {
        if contains(sensitiveFields, k) {
            masked[k] = "***MASKED***"
        } else {
            masked[k] = v
        }
    }
    return masked
}
```

### 4.2 Audit Trail with Vocabulary Context

**Enhanced audit logging:**

```go
// internal/server/audit.go - Enhanced

type AuditEntry struct {
    Timestamp          time.Time          `json:"timestamp"`
    QueryID            string             `json:"query_id"`
    Query              string             `json:"query"`
    QueryHash          string             `json:"query_hash"`
    ResolutionPath     string             `json:"resolution_path"`
    EntitiesAccessed   []EntityAccess     `json:"entities_accessed"`
    PersonalDataAccess *PersonalDataAudit `json:"personal_data_access,omitempty"`
    UserContext        map[string]string  `json:"user_context"`
}

type EntityAccess struct {
    EntityType        string   `json:"entity_type"`
    EntityID          string   `json:"entity_id"`
    FieldsAccessed    []string `json:"fields_accessed"`
    VocabularyContext string   `json:"vocabulary_context"` // e.g., "Common.SemanticObject=SalesOrder"
}

type PersonalDataAudit struct {
    DataSubjectAccessed bool     `json:"data_subject_accessed"`
    DataSubjectRole     string   `json:"data_subject_role,omitempty"`
    PersonalFields      []string `json:"personal_fields,omitempty"`
    SensitiveFields     []string `json:"sensitive_fields,omitempty"`
    LegalBasis          string   `json:"legal_basis,omitempty"`
}
```

---

## Phase 5: Cross-Platform Integration (Week 9-10)

### 5.1 CAP CDS Generator

**Generate CAP CDS from vocabulary annotations:**

```python
# scripts/vocab_to_cds.py

def generate_cds_annotations(entity_type: str, vocabulary_annotations: dict) -> str:
    """Generate CAP CDS annotations from OData vocabulary"""
    cds_lines = []
    
    # Common annotations
    if "Common" in vocabulary_annotations:
        common = vocabulary_annotations["Common"]
        if "Label" in common:
            cds_lines.append(f"  @Common.Label: '{common['Label']}'")
        if "SemanticObject" in common:
            cds_lines.append(f"  @Common.SemanticObject: '{common['SemanticObject']}'")
    
    # UI annotations
    if "UI" in vocabulary_annotations:
        ui = vocabulary_annotations["UI"]
        if "LineItem" in ui:
            cds_lines.append("  @UI.LineItem: [")
            for field in ui["LineItem"]:
                cds_lines.append(f"    {{ Value: {field['Value']} }},")
            cds_lines.append("  ]")
    
    # Analytics annotations
    if "Analytics" in vocabulary_annotations:
        analytics = vocabulary_annotations["Analytics"]
        for dim in analytics.get("Dimensions", []):
            cds_lines.append(f"  @Analytics.Dimension: true // {dim}")
        for measure in analytics.get("Measures", []):
            cds_lines.append(f"  @Analytics.Measure: true // {measure}")
    
    return "\n".join(cds_lines)
```

### 5.2 GraphQL Schema Generator

**Generate GraphQL schema from OData vocabulary:**

```python
# scripts/vocab_to_graphql.py

def generate_graphql_type(entity_type: str, properties: list, 
                          vocabulary_annotations: dict) -> str:
    """Generate GraphQL type from OData entity with vocabulary"""
    
    graphql_lines = [f"type {entity_type} {{"]
    
    for prop in properties:
        graphql_type = map_odata_to_graphql(prop["type"])
        nullable = "!" if not prop.get("nullable", True) else ""
        
        # Add descriptions from Common.Label
        description = ""
        if "Common" in vocabulary_annotations:
            labels = vocabulary_annotations["Common"].get("Labels", {})
            if prop["name"] in labels:
                description = f'  """{labels[prop["name"]]}"""\n'
        
        graphql_lines.append(f"{description}  {prop['name']}: {graphql_type}{nullable}")
    
    graphql_lines.append("}")
    return "\n".join(graphql_lines)

def map_odata_to_graphql(odata_type: str) -> str:
    mapping = {
        "Edm.String": "String",
        "Edm.Int32": "Int",
        "Edm.Int64": "Int",
        "Edm.Decimal": "Float",
        "Edm.Boolean": "Boolean",
        "Edm.DateTimeOffset": "DateTime",
        "Edm.Date": "Date",
        "Edm.Guid": "ID",
    }
    return mapping.get(odata_type, "String")
```

---

## Implementation Priority Matrix

| Improvement | Impact | Effort | Priority |
|------------|--------|--------|----------|
| Full XML vocabulary loading | High | Low | P1 |
| Mangle facts generation | High | Medium | P1 |
| Enhanced entity extraction | High | Medium | P1 |
| HANACloud vocabulary | Medium | Medium | P2 |
| Enhanced ES mapping | High | Medium | P2 |
| Vocabulary embeddings | High | Medium | P2 |
| Semantic term search | Medium | Low | P2 |
| PersonalData integration | High | Medium | P3 |
| Audit enhancements | Medium | Medium | P3 |
| CAP CDS generator | Medium | Low | P3 |
| GraphQL generator | Low | Medium | P4 |

---

## Success Metrics

| Metric | Current | Target | Measurement |
|--------|---------|--------|-------------|
| Vocabulary term coverage | ~50 terms | 331+ terms | Full XML loading |
| Entity extraction accuracy | ~70% | 95%+ | E2E test suite |
| Semantic search relevance | N/A | NDCG@10 > 0.8 | Embedding quality |
| HANA query routing | Partial | 100% analytical | Mangle rule coverage |
| GDPR field detection | Manual | Automated | PersonalData integration |
| Annotation generation | Manual | Auto-suggest | CAP/GraphQL generators |

---

*Improvement Plan Version: 1.0*
*Created: February 26, 2026*
*Owner: Platform Architecture Team*