"""
OpenAI Chat Completions Endpoint

POST /v1/chat/completions - Create chat completion
"""

import time
import uuid
import json
from typing import Dict, Any, List, Optional, Generator
from dataclasses import dataclass, field

from .models import resolve_model, is_chat_model, get_model_capabilities


@dataclass
class Message:
    """Chat message"""
    role: str  # system, user, assistant, function, tool
    content: Optional[str] = None
    name: Optional[str] = None
    function_call: Optional[Dict] = None
    tool_calls: Optional[List[Dict]] = None


@dataclass
class Choice:
    """Completion choice"""
    index: int
    message: Dict[str, Any]
    finish_reason: str = "stop"
    logprobs: Optional[Dict] = None


@dataclass  
class Usage:
    """Token usage"""
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int


def create_chat_completion(
    model: str,
    messages: List[Dict[str, Any]],
    temperature: float = 0.7,
    max_tokens: Optional[int] = None,
    stream: bool = False,
    tools: Optional[List[Dict]] = None,
    tool_choice: Optional[str] = None,
    functions: Optional[List[Dict]] = None,
    function_call: Optional[str] = None,
    **kwargs
) -> Dict[str, Any]:
    """
    Create a chat completion.
    
    OpenAI-compatible request/response format.
    Maps vocabulary operations to chat interface.
    """
    resolved_model = resolve_model(model)
    
    if not is_chat_model(model):
        return create_error_response(
            "invalid_request_error",
            f"Model {model} does not support chat completions"
        )
    
    # Extract user query from messages
    user_query = extract_user_query(messages)
    
    if stream:
        return create_streaming_response(resolved_model, user_query, messages)
    
    # Process based on model type
    if resolved_model == "odata-vocab-search":
        response_content = handle_search_query(user_query)
    elif resolved_model == "odata-vocab-annotator":
        response_content = handle_annotation_query(user_query, messages)
    elif resolved_model == "odata-vocab-generator":
        response_content = handle_generation_query(user_query, messages)
    elif resolved_model == "odata-vocab-gdpr":
        response_content = handle_gdpr_query(user_query, messages)
    else:
        response_content = handle_general_query(user_query)
    
    # Build response
    completion_id = f"chatcmpl-{uuid.uuid4().hex[:29]}"
    
    return {
        "id": completion_id,
        "object": "chat.completion",
        "created": int(time.time()),
        "model": resolved_model,
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": response_content
                },
                "finish_reason": "stop"
            }
        ],
        "usage": {
            "prompt_tokens": estimate_tokens(messages),
            "completion_tokens": estimate_tokens([{"content": response_content}]),
            "total_tokens": estimate_tokens(messages) + estimate_tokens([{"content": response_content}])
        }
    }


def extract_user_query(messages: List[Dict[str, Any]]) -> str:
    """Extract the user's query from messages"""
    for msg in reversed(messages):
        if msg.get("role") == "user":
            return msg.get("content", "")
    return ""


def estimate_tokens(messages: List[Dict]) -> int:
    """Rough token estimation (4 chars per token)"""
    total_chars = sum(len(str(m.get("content", ""))) for m in messages)
    return max(1, total_chars // 4)


def handle_search_query(query: str) -> str:
    """Handle vocabulary search queries"""
    # Extract search terms
    search_terms = query.lower()
    
    # Common vocabulary term patterns
    term_info = {
        "lineitem": {
            "qualified_name": "UI.LineItem",
            "description": "Collection of data fields for display in a table or list",
            "vocabulary": "UI",
            "type": "Collection(UI.DataFieldAbstract)"
        },
        "headerinfo": {
            "qualified_name": "UI.HeaderInfo",
            "description": "Header information for an entity displayed on object pages",
            "vocabulary": "UI",
            "type": "UI.HeaderInfoType"
        },
        "selectionfields": {
            "qualified_name": "UI.SelectionFields",
            "description": "Properties for selection criteria in filter bars",
            "vocabulary": "UI",
            "type": "Collection(Edm.PropertyPath)"
        },
        "label": {
            "qualified_name": "Common.Label",
            "description": "Human-readable label for a property or entity",
            "vocabulary": "Common",
            "type": "Edm.String"
        },
        "measure": {
            "qualified_name": "Analytics.Measure",
            "description": "Indicates the property is an analytics measure/KPI",
            "vocabulary": "Analytics",
            "type": "Edm.Boolean"
        }
    }
    
    # Find matching terms
    matches = []
    for key, info in term_info.items():
        if key in search_terms:
            matches.append(info)
    
    if matches:
        response = "I found the following OData vocabulary terms:\n\n"
        for match in matches:
            response += f"**{match['qualified_name']}**\n"
            response += f"- Description: {match['description']}\n"
            response += f"- Type: {match['type']}\n"
            response += f"- Vocabulary: {match['vocabulary']}\n\n"
        return response
    
    return f"I searched the OData vocabularies for '{query}'. Please try terms like 'LineItem', 'HeaderInfo', 'SelectionFields', 'Label', or 'Measure'."


def handle_annotation_query(query: str, messages: List[Dict]) -> str:
    """Handle annotation suggestion queries"""
    # Look for entity definition in messages
    entity_info = extract_entity_from_messages(messages)
    
    if entity_info:
        annotations = suggest_annotations_for_entity(entity_info)
        return format_annotation_response(entity_info, annotations)
    
    return """To suggest annotations, I need entity information. Please provide:

1. Entity name
2. Properties with types

Example:
```json
{
  "name": "Product",
  "properties": [
    {"name": "ProductID", "type": "Edm.String"},
    {"name": "ProductName", "type": "Edm.String"},
    {"name": "Price", "type": "Edm.Decimal"}
  ]
}
```"""


def handle_generation_query(query: str, messages: List[Dict]) -> str:
    """Handle code generation queries"""
    query_lower = query.lower()
    
    entity_info = extract_entity_from_messages(messages)
    
    if "cds" in query_lower:
        return generate_cds_code(entity_info or get_sample_entity())
    elif "graphql" in query_lower:
        return generate_graphql_code(entity_info or get_sample_entity())
    elif "sql" in query_lower:
        return generate_sql_code(entity_info or get_sample_entity())
    
    return """I can generate code in these formats:
- **CDS**: SAP CAP CDS entity definitions with annotations
- **GraphQL**: GraphQL type definitions
- **SQL**: HANA Cloud DDL statements

Please specify what you'd like to generate."""


def handle_gdpr_query(query: str, messages: List[Dict]) -> str:
    """Handle GDPR/personal data queries"""
    entity_info = extract_entity_from_messages(messages)
    
    if entity_info:
        classification = classify_personal_data(entity_info)
        return format_gdpr_response(entity_info, classification)
    
    return """To classify personal data, I need entity information with field names.

Personal data indicators I detect:
- **Email, Phone, Address** - Contact information
- **Name, FirstName, LastName** - Personal names
- **SSN, TaxID, Passport** - Identifiers
- **Health, Medical, Religion** - Sensitive data (GDPR Article 9)

Please provide your entity definition."""


def handle_general_query(query: str) -> str:
    """Handle general vocabulary queries"""
    return f"""I can help with OData vocabulary operations:

1. **Search Terms**: Find vocabulary terms by keyword
2. **Suggest Annotations**: Get annotation suggestions for entities
3. **Generate Code**: Create CDS, GraphQL, or SQL from entities
4. **GDPR Classification**: Identify personal data fields

Your query: "{query}"

Please specify what you'd like me to help with."""


def extract_entity_from_messages(messages: List[Dict]) -> Optional[Dict]:
    """Extract entity definition from message content"""
    for msg in messages:
        content = msg.get("content", "")
        if isinstance(content, str) and "{" in content:
            try:
                # Try to parse JSON entity
                start = content.find("{")
                end = content.rfind("}") + 1
                if start >= 0 and end > start:
                    return json.loads(content[start:end])
            except json.JSONDecodeError:
                pass
    return None


def get_sample_entity() -> Dict:
    """Return a sample entity for demo purposes"""
    return {
        "name": "Product",
        "properties": [
            {"name": "ProductID", "type": "Edm.String", "isKey": True},
            {"name": "ProductName", "type": "Edm.String"},
            {"name": "Price", "type": "Edm.Decimal"}
        ]
    }


def suggest_annotations_for_entity(entity: Dict) -> Dict:
    """Generate annotation suggestions"""
    annotations = {"@UI.LineItem": [], "@UI.HeaderInfo": {}}
    
    for prop in entity.get("properties", []):
        name = prop.get("name", "")
        prop_type = prop.get("type", "")
        
        # UI.LineItem
        annotations["@UI.LineItem"].append({
            "@UI.DataField": {
                "Value": name,
                "@UI.Importance": "#High" if prop.get("isKey") else "#Medium"
            }
        })
        
        # Detect measures
        if prop_type in ["Edm.Decimal", "Edm.Double", "Edm.Int32"]:
            if any(m in name.lower() for m in ["amount", "price", "total", "quantity"]):
                annotations[f"{name}@Analytics.Measure"] = True
    
    # HeaderInfo
    key_prop = next((p for p in entity.get("properties", []) if p.get("isKey")), None)
    annotations["@UI.HeaderInfo"] = {
        "TypeName": entity.get("name", "Entity"),
        "TypeNamePlural": entity.get("name", "Entity") + "s",
        "Title": {"Value": key_prop.get("name") if key_prop else "ID"}
    }
    
    return annotations


def format_annotation_response(entity: Dict, annotations: Dict) -> str:
    """Format annotation suggestions as readable response"""
    response = f"## Suggested Annotations for {entity.get('name', 'Entity')}\n\n"
    response += "```json\n"
    response += json.dumps(annotations, indent=2)
    response += "\n```\n\n"
    response += "### Applied Annotations:\n"
    response += "- **@UI.LineItem**: Table column definitions\n"
    response += "- **@UI.HeaderInfo**: Object page header\n"
    return response


def generate_cds_code(entity: Dict) -> str:
    """Generate CDS entity definition"""
    name = entity.get("name", "Entity")
    props = entity.get("properties", [])
    
    cds = f"entity {name} {{\n"
    for prop in props:
        key_prefix = "key " if prop.get("isKey") else "    "
        cds_type = map_edm_to_cds(prop.get("type", "Edm.String"))
        cds += f"  {key_prefix}{prop.get('name')}: {cds_type};\n"
    cds += "}\n"
    
    return f"```cds\n{cds}```"


def generate_graphql_code(entity: Dict) -> str:
    """Generate GraphQL type definition"""
    name = entity.get("name", "Entity")
    props = entity.get("properties", [])
    
    gql = f"type {name} {{\n"
    for prop in props:
        gql_type = map_edm_to_graphql(prop.get("type", "Edm.String"))
        nullable = "!" if prop.get("isKey") else ""
        gql += f"  {prop.get('name')}: {gql_type}{nullable}\n"
    gql += "}\n"
    
    return f"```graphql\n{gql}```"


def generate_sql_code(entity: Dict) -> str:
    """Generate HANA SQL DDL"""
    name = entity.get("name", "Entity").upper()
    props = entity.get("properties", [])
    
    sql = f"CREATE TABLE {name} (\n"
    columns = []
    keys = []
    for prop in props:
        sql_type = map_edm_to_sql(prop.get("type", "Edm.String"))
        null = "NOT NULL" if prop.get("isKey") else "NULL"
        columns.append(f"  {prop.get('name')} {sql_type} {null}")
        if prop.get("isKey"):
            keys.append(prop.get("name"))
    
    sql += ",\n".join(columns)
    if keys:
        sql += f",\n  PRIMARY KEY ({', '.join(keys)})"
    sql += "\n);\n"
    
    return f"```sql\n{sql}```"


def classify_personal_data(entity: Dict) -> Dict:
    """Classify personal data in entity"""
    personal_patterns = ["email", "phone", "address", "name", "firstname", "lastname"]
    sensitive_patterns = ["health", "medical", "religion", "ethnic", "political"]
    
    classification = {
        "has_personal_data": False,
        "has_sensitive_data": False,
        "personal_fields": [],
        "sensitive_fields": [],
        "recommendations": []
    }
    
    for prop in entity.get("properties", []):
        name = prop.get("name", "").lower()
        
        if any(p in name for p in personal_patterns):
            classification["personal_fields"].append(prop.get("name"))
            classification["has_personal_data"] = True
        
        if any(p in name for p in sensitive_patterns):
            classification["sensitive_fields"].append(prop.get("name"))
            classification["has_sensitive_data"] = True
    
    return classification


def format_gdpr_response(entity: Dict, classification: Dict) -> str:
    """Format GDPR classification response"""
    response = f"## GDPR Analysis for {entity.get('name', 'Entity')}\n\n"
    
    if classification["has_sensitive_data"]:
        response += "⚠️ **Contains Sensitive Personal Data (GDPR Art. 9)**\n\n"
    elif classification["has_personal_data"]:
        response += "⚠️ **Contains Personal Data**\n\n"
    else:
        response += "✅ **No personal data detected**\n\n"
    
    if classification["personal_fields"]:
        response += f"**Personal Fields**: {', '.join(classification['personal_fields'])}\n"
    if classification["sensitive_fields"]:
        response += f"**Sensitive Fields**: {', '.join(classification['sensitive_fields'])}\n"
    
    return response


def map_edm_to_cds(edm_type: str) -> str:
    """Map OData EDM type to CDS type"""
    mapping = {
        "Edm.String": "String",
        "Edm.Int32": "Integer",
        "Edm.Int64": "Integer64",
        "Edm.Decimal": "Decimal",
        "Edm.Boolean": "Boolean",
        "Edm.Date": "Date",
        "Edm.DateTimeOffset": "Timestamp"
    }
    return mapping.get(edm_type, "String")


def map_edm_to_graphql(edm_type: str) -> str:
    """Map OData EDM type to GraphQL type"""
    mapping = {
        "Edm.String": "String",
        "Edm.Int32": "Int",
        "Edm.Int64": "Int",
        "Edm.Decimal": "Float",
        "Edm.Boolean": "Boolean",
        "Edm.Date": "String",
        "Edm.DateTimeOffset": "String"
    }
    return mapping.get(edm_type, "String")


def map_edm_to_sql(edm_type: str) -> str:
    """Map OData EDM type to HANA SQL type"""
    mapping = {
        "Edm.String": "NVARCHAR(255)",
        "Edm.Int32": "INTEGER",
        "Edm.Int64": "BIGINT",
        "Edm.Decimal": "DECIMAL(15,2)",
        "Edm.Boolean": "BOOLEAN",
        "Edm.Date": "DATE",
        "Edm.DateTimeOffset": "TIMESTAMP"
    }
    return mapping.get(edm_type, "NVARCHAR(255)")


def create_streaming_response(model: str, query: str, messages: List[Dict]) -> Generator:
    """Create streaming response (SSE format)"""
    completion_id = f"chatcmpl-{uuid.uuid4().hex[:29]}"
    
    # Get response content
    response_content = handle_general_query(query)
    
    # Stream chunks
    for i, char in enumerate(response_content):
        chunk = {
            "id": completion_id,
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": model,
            "choices": [{
                "index": 0,
                "delta": {"content": char} if i > 0 else {"role": "assistant", "content": char},
                "finish_reason": None
            }]
        }
        yield f"data: {json.dumps(chunk)}\n\n"
    
    # Final chunk
    final_chunk = {
        "id": completion_id,
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "delta": {},
            "finish_reason": "stop"
        }]
    }
    yield f"data: {json.dumps(final_chunk)}\n\n"
    yield "data: [DONE]\n\n"


def create_error_response(error_type: str, message: str) -> Dict[str, Any]:
    """Create OpenAI-compatible error response"""
    return {
        "error": {
            "message": message,
            "type": error_type,
            "param": None,
            "code": None
        }
    }