% ===----------------------------------------------------------------------=== %
% ToonSPy SAP AI Core Schemas in Mangle
%
% Schema definitions and validation rules specific to SAP AI Core deployments.
% ===----------------------------------------------------------------------=== %

% ============================================================================ %
% AI Core Deployment Configuration
% ============================================================================ %

% AI Core deployment: deployment(Id, ScenarioId, Model, ResourceGroup)
deployment(Id, ScenarioId, Model, ResourceGroup).

% Supported models in AI Core
supported_model("gpt-4").
supported_model("gpt-4-turbo").
supported_model("gpt-3.5-turbo").
supported_model("claude-3-opus").
supported_model("claude-3-sonnet").
supported_model("gemini-pro").
supported_model("llama-2-70b").

% Validate deployment configuration
valid_deployment(deployment(Id, ScenarioId, Model, ResourceGroup)) :-
    fn:is_string(Id),
    fn:is_string(ScenarioId),
    supported_model(Model),
    fn:is_string(ResourceGroup).

% ============================================================================ %
% AI Core Request/Response Schemas
% ============================================================================ %

% Request schema for chat completion
request_schema(chat_completion, [
    field(messages, array, required),
    field(max_tokens, int, optional),
    field(temperature, float, optional),
    field(model, string, optional)
]).

% TOON request format (more compact than JSON)
toon_request(Prompt, ToonReq) :-
    fn:format("prompt:%s max_tokens:512 temp:0.1", [Prompt], ToonReq).

% Valid AI Core response
valid_aicore_response(Response) :-
    fn:has_key(Response, "choices"),
    fn:get(Response, "choices", Choices),
    fn:length(Choices, Len),
    Len > 0.

% Extract content from AI Core response
extract_content(Response, Content) :-
    fn:get(Response, "choices", Choices),
    fn:first(Choices, First),
    fn:get(First, "message", Message),
    fn:get(Message, "content", Content).

% ============================================================================ %
% TOON Output Validation for AI Core
% ============================================================================ %

% Validate TOON output from AI Core
valid_toon_output(ToonStr) :-
    toon:parse(ToonStr, Parsed),
    fn:is_object(Parsed).

% Validate specific field in TOON output
valid_toon_field(ToonStr, FieldName, Type) :-
    toon:parse(ToonStr, Parsed),
    fn:get(Parsed, FieldName, Value),
    valid_field_type(Value, Type).

% Error handling for invalid TOON
toon_error(ToonStr, "parse_error") :-
    \+ toon:parse(ToonStr, _).

toon_error(ToonStr, "missing_field") :-
    toon:parse(ToonStr, Parsed),
    required_field(Field),
    \+ fn:has_key(Parsed, Field).

% ============================================================================ %
% Log Analysis Schemas (rustshimmy-specific)
% ============================================================================ %

% Valid log severity levels
log_severity("debug").
log_severity("info").
log_severity("warn").
log_severity("error").
log_severity("critical").

% Valid log categories
log_category("database").
log_category("network").
log_category("authentication").
log_category("authorization").
log_category("application").
log_category("system").
log_category("security").

% Validate log analysis output
valid_log_analysis(ToonStr) :-
    toon:parse(ToonStr, Parsed),
    fn:get(Parsed, "severity", Sev),
    log_severity(Sev),
    fn:has_key(Parsed, "category"),
    fn:has_key(Parsed, "message").

% Extract action from log analysis
log_action(ToonStr, Action) :-
    toon:parse(ToonStr, Parsed),
    fn:get(Parsed, "action", Action).

% Default actions for severity levels
default_action("debug", "log_only").
default_action("info", "log_only").
default_action("warn", "monitor").
default_action("error", "alert_ops").
default_action("critical", "page_oncall").

% ============================================================================ %
% Rate Limiting and Quotas
% ============================================================================ %

% Rate limit configuration
rate_limit(ResourceGroup, RequestsPerMinute, TokensPerMinute).

% Default rate limits
rate_limit("default", 60, 100000).
rate_limit("premium", 300, 500000).
rate_limit("enterprise", 1000, 2000000).

% Check if within rate limit
within_rate_limit(ResourceGroup, CurrentRequests, CurrentTokens) :-
    rate_limit(ResourceGroup, MaxReq, MaxTok),
    CurrentRequests =< MaxReq,
    CurrentTokens =< MaxTok.

% ============================================================================ %
% Token Usage Tracking
% ============================================================================ %

% Track token usage: usage(RequestId, InputTokens, OutputTokens, TotalTokens)
usage(RequestId, InputTokens, OutputTokens, TotalTokens) :-
    TotalTokens is InputTokens + OutputTokens.

% TOON format saves tokens compared to JSON
toon_savings(JsonTokens, ToonTokens, Savings) :-
    Savings is (JsonTokens - ToonTokens) / JsonTokens * 100.

% Typical savings expectations
expected_savings(predict, 50).      % 50% savings for simple predict
expected_savings(cot, 45).          % 45% savings for CoT
expected_savings(react, 40).        % 40% savings for ReAct (more verbose)

% ============================================================================ %
% Error Recovery Rules
% ============================================================================ %

% Retry strategy based on error type
retry_strategy("rate_limit", exponential_backoff, 3).
retry_strategy("timeout", linear_backoff, 2).
retry_strategy("parse_error", immediate, 1).
retry_strategy("auth_error", none, 0).

% Should retry based on error
should_retry(Error, Strategy, MaxRetries) :-
    retry_strategy(Error, Strategy, MaxRetries),
    MaxRetries > 0.

% ============================================================================ %
% AI Core Scenario Definitions
% ============================================================================ %

% ToonSPy scenario for log analysis
scenario(toonspy_log_analysis, [
    model("gpt-4"),
    purpose("Analyze logs and extract structured TOON output"),
    signatures([log_analysis, entity_extraction]),
    rate_limit(60, 100000)
]).

% ToonSPy scenario for general inference
scenario(toonspy_inference, [
    model("gpt-4-turbo"),
    purpose("General ToonSPy inference with TOON output"),
    signatures([sentiment_classification, question_answering, summarization]),
    rate_limit(120, 200000)
]).

% ToonSPy scenario for agents
scenario(toonspy_agents, [
    model("gpt-4"),
    purpose("ReAct agents with tool use and TOON output"),
    signatures([react_agent]),
    rate_limit(30, 150000)
]).