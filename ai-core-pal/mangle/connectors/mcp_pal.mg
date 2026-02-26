// ============================================================================
// MCP PAL Connector - Model Context Protocol with HANA PAL
// ============================================================================
// MCP server operations combined with HANA Predictive Analysis Library.

// ============================================================================
// MCP Server Configuration
// ============================================================================

Decl mcp_server(
    server_id: String,
    name: String,
    version: String,
    protocol_version: String,   // MCP protocol version
    transport: String           // stdio, sse, websocket
).

Decl mcp_server_capability(
    server_id: String,
    capability: String          // tools, resources, prompts, sampling
).

// ============================================================================
// MCP Tools
// ============================================================================

Decl mcp_tool(
    tool_id: String,
    server_id: String,
    name: String,
    description: String,
    input_schema: String        // JSON Schema
).

Decl mcp_tool_parameter(
    tool_id: String,
    param_name: String,
    param_type: String,
    required: i32,
    description: String
).

// Tool invocation
Decl mcp_tool_call(
    call_id: String,
    tool_id: String,
    arguments: String,          // JSON
    requested_at: i64
).

// Tool result
Decl mcp_tool_result(
    call_id: String,
    content: String,            // JSON or text
    is_error: i32,
    duration_ms: i64
).

// ============================================================================
// MCP Resources
// ============================================================================

Decl mcp_resource(
    resource_id: String,
    server_id: String,
    uri: String,
    name: String,
    description: String,
    mime_type: String
).

Decl mcp_resource_template(
    template_id: String,
    server_id: String,
    uri_template: String,       // RFC 6570 URI template
    name: String,
    description: String
).

// Resource read
Decl mcp_resource_read(
    read_id: String,
    resource_id: String,
    requested_at: i64
).

Decl mcp_resource_content(
    read_id: String,
    content_ref: String,        // TOON pointer
    mime_type: String,
    duration_ms: i64,
    status: String
).

// ============================================================================
// MCP Prompts
// ============================================================================

Decl mcp_prompt(
    prompt_id: String,
    server_id: String,
    name: String,
    description: String,
    arguments_schema: String    // JSON Schema for arguments
).

Decl mcp_prompt_message(
    message_id: String,
    prompt_id: String,
    role: String,               // user, assistant
    content_type: String,       // text, image, resource
    content: String
).

// ============================================================================
// HANA PAL Functions
// ============================================================================

// PAL function registry
Decl pal_function(
    function_id: String,
    name: String,
    category: String,           // classification, regression, clustering, timeseries, etc.
    input_tables: String,       // JSON array of table specs
    output_tables: String,      // JSON array of table specs
    parameters: String          // JSON array of parameter specs
).

// PAL function execution
Decl pal_execution(
    exec_id: String,
    service_id: String,
    function_id: String,
    input_refs: String,         // TOON pointers to input data
    parameters: String,         // JSON of parameter values
    requested_at: i64
).

Decl pal_result(
    exec_id: String,
    output_refs: String,        // TOON pointers to output tables
    model_ref: String,          // TOON pointer to trained model (if any)
    metrics: String,            // JSON of performance metrics
    duration_ms: i64,
    status: String
).

// ============================================================================
// PAL-as-MCP-Tool Bindings
// ============================================================================

// Bind PAL function as MCP tool
Decl pal_tool_binding(
    binding_id: String,
    tool_id: String,
    function_id: String,
    input_mapping: String,      // JSON: tool args → PAL inputs
    output_mapping: String      // JSON: PAL outputs → tool result
).

// ============================================================================
// Mesh Gateway
// ============================================================================

// Connected MCP servers in the mesh
Decl mesh_server(
    server_id: String,
    endpoint: String,
    transport: String,
    status: String,             // connected, disconnected, error
    last_heartbeat: i64
).

// Route tool calls to servers
Decl mesh_route(
    route_id: String,
    tool_pattern: String,       // Glob pattern for tool names
    target_server: String,
    priority: i32
).

// ============================================================================
// Rules - MCP Server
// ============================================================================

// Server is ready
server_ready(ServerId) :-
    mcp_server(ServerId, _, _, _, _),
    mcp_server_capability(ServerId, "tools").

// Server supports capability
has_capability(ServerId, Cap) :-
    mcp_server_capability(ServerId, Cap).

// ============================================================================
// Rules - Tool Operations
// ============================================================================

// Tool is available
tool_available(ToolId) :-
    mcp_tool(ToolId, ServerId, _, _, _),
    server_ready(ServerId).

// Tool call succeeded
tool_call_succeeded(CallId) :-
    mcp_tool_result(CallId, _, 0, _).

// Tool call failed
tool_call_failed(CallId) :-
    mcp_tool_result(CallId, _, 1, _).

// ============================================================================
// Rules - PAL Operations
// ============================================================================

// PAL function available
pal_available(FunctionId) :-
    pal_function(FunctionId, _, _, _, _, _),
    hana_healthy("ai-core-pal", _).

// PAL execution succeeded
pal_succeeded(ExecId) :-
    pal_result(ExecId, _, _, _, _, "success").

// PAL as tool is ready
pal_tool_ready(ToolId) :-
    pal_tool_binding(_, ToolId, FunctionId, _, _),
    tool_available(ToolId),
    pal_available(FunctionId).

// ============================================================================
// Rules - Mesh Routing
// ============================================================================

// Server is healthy in mesh
mesh_server_healthy(ServerId) :-
    mesh_server(ServerId, _, _, "connected", LastHB),
    now(Now),
    Now - LastHB < 60000.  // 60 second timeout

// Find route for tool
route_for_tool(ToolName, ServerId, Priority) :-
    mesh_route(_, Pattern, ServerId, Priority),
    glob_match(Pattern, ToolName),
    mesh_server_healthy(ServerId).

// Best route (highest priority healthy server)
best_route(ToolName, ServerId) :-
    route_for_tool(ToolName, ServerId, Priority),
    not((route_for_tool(ToolName, _, P2), P2 > Priority)).