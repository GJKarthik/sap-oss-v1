# ============================================================================
# UI5 Web Components Angular - Agent-to-Agent (A2A) MCP Protocol
#
# Service registry and routing rules for UI5 Web Components MCP communication.
# ============================================================================

# 1. Service Registry
service_registry("ui5-components",  "http://localhost:9160/mcp",  "component-registry").
service_registry("ui5-generator",   "http://localhost:9160/mcp",  "template-generator").
service_registry("ui5-validator",   "http://localhost:9160/mcp",  "template-validator").

# 2. Intent Routing
resolve_service_for_intent(/components, URL) :-
    service_registry("ui5-components", URL, _).

resolve_service_for_intent(/generate, URL) :-
    service_registry("ui5-generator", URL, _).

resolve_service_for_intent(/validate, URL) :-
    service_registry("ui5-validator", URL, _).

# 3. Tool Routing
tool_service("list_components", "ui5-components").
tool_service("get_component", "ui5-components").
tool_service("generate_angular_template", "ui5-generator").
tool_service("generate_module_imports", "ui5-generator").
tool_service("search_components", "ui5-components").
tool_service("validate_template", "ui5-validator").
tool_service("mangle_query", "ui5-components").

# 4. Component Facts
ui5_component("ui5-button", "Ui5ButtonModule").
ui5_component("ui5-input", "Ui5InputModule").
ui5_component("ui5-table", "Ui5TableModule").
ui5_component("ui5-dialog", "Ui5DialogModule").
ui5_component("ui5-card", "Ui5CardModule").
ui5_component("ui5-list", "Ui5ListModule").
ui5_component("ui5-panel", "Ui5PanelModule").
ui5_component("ui5-tabcontainer", "Ui5TabContainerModule").