# ============================================================================
# OData Vocabularies - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for OData Vocabularies MCP communication.
# ============================================================================

# 1. Service Registry
service_registry("odata-vocab",     "http://localhost:9150/mcp",  "vocabulary-engine").
service_registry("odata-annotate", "http://localhost:9150/mcp",  "annotation-generator").
service_registry("odata-validate", "http://localhost:9150/mcp",  "validator").

# Graph-RAG: embedded KùzuDB vocabulary/term/annotation-target relationship graph
service_registry("odata-graph",    "http://localhost:9150/mcp",  "graph-rag").

# 2. Intent Routing
resolve_service_for_intent(/vocabulary, URL) :-
    service_registry("odata-vocab", URL, _).

resolve_service_for_intent(/annotate, URL) :-
    service_registry("odata-annotate", URL, _).

resolve_service_for_intent(/validate, URL) :-
    service_registry("odata-validate", URL, _).

resolve_service_for_intent(/graph_index, URL) :-
    service_registry("odata-graph", URL, _).

resolve_service_for_intent(/graph_query, URL) :-
    service_registry("odata-graph", URL, _).

# 3. Tool Routing
tool_service("list_vocabularies", "odata-vocab").
tool_service("get_vocabulary", "odata-vocab").
tool_service("search_terms", "odata-vocab").
tool_service("validate_annotations", "odata-validate").
tool_service("generate_annotations", "odata-annotate").
tool_service("lookup_term", "odata-vocab").
tool_service("convert_annotations", "odata-annotate").
tool_service("mangle_query",  "odata-vocab").
tool_service("kuzu_index",    "odata-graph").
tool_service("kuzu_query",    "odata-graph").

# 4. Vocabulary Facts
vocabulary("Common", "com.sap.vocabularies.Common.v1").
vocabulary("UI", "com.sap.vocabularies.UI.v1").
vocabulary("Analytics", "com.sap.vocabularies.Analytics.v1").
vocabulary("Communication", "com.sap.vocabularies.Communication.v1").
vocabulary("PersonalData", "com.sap.vocabularies.PersonalData.v1").