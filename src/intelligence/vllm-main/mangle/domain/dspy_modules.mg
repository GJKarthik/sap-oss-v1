% ===----------------------------------------------------------------------=== %
% ToonSPy DSPy Module Templates in Mangle — Dynamic Fact-Based
% ============================================================================
% NO HARDCODED VALUES — All signatures are injected at runtime.
% This file contains only FACT SCHEMAS and DERIVATION RULES.
% ===----------------------------------------------------------------------=== %

% ============================================================================ %
% FACT SCHEMAS (injected at runtime, NOT defined here)
% ============================================================================ %
%
% Signature facts (registered by service at startup):
%   signature(Name, Description, Inputs, Outputs).
%   signature_registered(Name, ServiceID, Timestamp).
%
% Input field facts:
%   input_field(SigName, FieldName, Description, Required, DefaultValue).
%
% Output field facts:
%   output_field(SigName, FieldName, Type, Constraints).
%   % Type: string, int, float, bool, array, enum
%   % Constraints: none, range(Min, Max), Values list for enum
%
% Tool facts (for ReAct):
%   tool(Name, Description, Params).
%   tool_registered(Name, ServiceID, Timestamp).
%
% Execution context:
%   current_signature(Name).
%   current_model(ModelName).
%   current_session(SessionID).

% ============================================================================ %
% DERIVED: TOON Format Generation
% ============================================================================ %

% Generate TOON output specification for an output field
derive_toon_spec(SigName, FieldName, Spec) :-
    output_field(SigName, FieldName, string, _),
    fn:format("%s:<value>", [FieldName], Spec).

derive_toon_spec(SigName, FieldName, Spec) :-
    output_field(SigName, FieldName, int, range(Min, Max)),
    fn:format("%s:<%d-%d>", [FieldName, Min, Max], Spec).

derive_toon_spec(SigName, FieldName, Spec) :-
    output_field(SigName, FieldName, int, none),
    fn:format("%s:<number>", [FieldName], Spec).

derive_toon_spec(SigName, FieldName, Spec) :-
    output_field(SigName, FieldName, float, range(Min, Max)),
    fn:format("%s:<%.1f-%.1f>", [FieldName, Min, Max], Spec).

derive_toon_spec(SigName, FieldName, Spec) :-
    output_field(SigName, FieldName, float, none),
    fn:format("%s:<decimal>", [FieldName], Spec).

derive_toon_spec(SigName, FieldName, Spec) :-
    output_field(SigName, FieldName, bool, _),
    fn:format("%s:<true|false>", [FieldName], Spec).

derive_toon_spec(SigName, FieldName, Spec) :-
    output_field(SigName, FieldName, array, _),
    fn:format("%s:<val1|val2|...>", [FieldName], Spec).

derive_toon_spec(SigName, FieldName, Spec) :-
    output_field(SigName, FieldName, enum, Values),
    fn:join(Values, "|", ValuesStr),
    fn:format("%s:<%s>", [FieldName, ValuesStr], Spec).

% ============================================================================ %
% DERIVED: Prompt Generation Rules
% ============================================================================ %

% Generate full output spec for a signature
generate_output_spec(SigName, Spec) :-
    findall(S, derive_toon_spec(SigName, _, S), Specs),
    fn:join(Specs, " ", Spec).

% Format input values for prompt
format_input_values([], "").
format_input_values([(Name, Value)|Rest], Str) :-
    format_input_values(Rest, RestStr),
    fn:format("%s: %s\n%s", [Name, Value, RestStr], Str).

% Generate Predict prompt
predict_prompt(SigName, InputValues, Prompt) :-
    signature(SigName, Description, _, _),
    generate_output_spec(SigName, OutputSpec),
    format_input_values(InputValues, InputStr),
    fn:format("%s\n\nRespond in TOON format:\n%s\n\nInput:\n%s\n\nOutput:",
              [Description, OutputSpec, InputStr], Prompt).

% Generate Chain of Thought prompt
cot_prompt(SigName, InputValues, Prompt) :-
    signature(SigName, Description, _, _),
    generate_output_spec(SigName, OutputSpec),
    format_input_values(InputValues, InputStr),
    fn:format("%s\n\nThink step by step, then provide your answer.\n\nRespond in TOON format:\nreasoning:<step1>|<step2>|<step3> %s\n\nInput:\n%s\n\nOutput:",
              [Description, OutputSpec, InputStr], Prompt).

% ============================================================================ %
% DERIVED: ReAct Prompt Rules
% ============================================================================ %

% Format tools list
format_tools([], "").
format_tools([ToolName|Rest], Str) :-
    tool(ToolName, Desc, Params),
    fn:join(Params, ", ", ParamStr),
    format_tools(Rest, RestStr),
    fn:format("- %s: %s (params: %s)\n%s", [ToolName, Desc, ParamStr, RestStr], Str).

% Format execution history
format_history([], "").
format_history([step(Thought, Action, Input, Obs)|Rest], Str) :-
    format_history(Rest, RestStr),
    fn:format("\nPrevious: thought:%s action:%s input:%s\nobservation:%s%s",
              [Thought, Action, Input, Obs, RestStr], Str).

% Generate ReAct prompt with tools
react_prompt(SigName, ToolNames, InputValues, History, Prompt) :-
    signature(SigName, Description, _, _),
    format_tools(ToolNames, ToolStr),
    format_input_values(InputValues, InputStr),
    format_history(History, HistoryStr),
    fn:format("%s\n\nAvailable tools:\n%s\n\nRespond in TOON format:\nthought:<reasoning> action:<tool> input:<args>\nOR: thought:<reasoning> action:finish answer:<final>\n\nQuestion:\n%s\n%s\nNext step:",
              [Description, ToolStr, InputStr, HistoryStr], Prompt).

% ============================================================================ %
% DERIVED: Validation Rules
% ============================================================================ %

% Validate TOON output has required fields
valid_output(ToonStr, SigName) :-
    toon:parse(ToonStr, Parsed),
    all_required_fields_present(Parsed, SigName).

% Check all required fields are present
all_required_fields_present(Parsed, SigName) :-
    forall(
        (output_field(SigName, FieldName, _, _)),
        fn:has_key(Parsed, FieldName)
    ).

% Validate field types
valid_field_type(Value, string) :- fn:is_string(Value).
valid_field_type(Value, int) :- fn:is_int(Value).
valid_field_type(Value, float) :- fn:is_float(Value).
valid_field_type(Value, bool) :- fn:member(Value, [true, false]).
valid_field_type(Value, array) :- fn:is_array(Value).
valid_field_type(Value, enum(Vals)) :- fn:member(Value, Vals).

% Validate range constraints
valid_range(Value, range(Min, Max)) :-
    Value >= Min,
    Value =< Max.

valid_range(_, none).

% Full field validation
valid_field(SigName, FieldName, Value) :-
    output_field(SigName, FieldName, Type, Constraints),
    valid_field_type(Value, Type),
    valid_range(Value, Constraints).

% Validate entire output
validate_output(SigName, ToonStr) :-
    toon:parse(ToonStr, Parsed),
    forall(
        output_field(SigName, FieldName, _, _),
        (fn:get(Parsed, FieldName, Value), valid_field(SigName, FieldName, Value))
    ).

% ============================================================================ %
% DERIVED: Signature Discovery
% ============================================================================ %

% List all registered signatures for a service
signatures_for_service(ServiceID, Signatures) :-
    findall(Name, signature_registered(Name, ServiceID, _), Signatures).

% List all available tools for a service
tools_for_service(ServiceID, Tools) :-
    findall(Name, tool_registered(Name, ServiceID, _), Tools).

% Get signature input requirements
signature_inputs(SigName, Inputs) :-
    findall(
        input(Name, Desc, Req, Def),
        input_field(SigName, Name, Desc, Req, Def),
        Inputs
    ).

% Get signature output specification
signature_outputs(SigName, Outputs) :-
    findall(
        output(Name, Type, Constraints),
        output_field(SigName, Name, Type, Constraints),
        Outputs
    ).

% ============================================================================ %
% DERIVED: Module Selection
% ============================================================================ %

% Select module type based on task complexity
select_module_type(SigName, predict) :-
    signature_outputs(SigName, Outputs),
    length(Outputs, N),
    N =< 2.

select_module_type(SigName, chain_of_thought) :-
    signature_outputs(SigName, Outputs),
    length(Outputs, N),
    N > 2,
    N =< 5.

select_module_type(SigName, react) :-
    tools_for_service(_, Tools),
    length(Tools, TN),
    TN > 0.

% ============================================================================ %
% DERIVED: Batch Execution
% ============================================================================ %

% Generate batch of prompts for multiple inputs
batch_prompts(SigName, InputsList, Prompts) :-
    select_module_type(SigName, ModuleType),
    generate_batch(SigName, ModuleType, InputsList, Prompts).

generate_batch(_, _, [], []).
generate_batch(SigName, predict, [Inputs|Rest], [Prompt|RestPrompts]) :-
    predict_prompt(SigName, Inputs, Prompt),
    generate_batch(SigName, predict, Rest, RestPrompts).

generate_batch(SigName, chain_of_thought, [Inputs|Rest], [Prompt|RestPrompts]) :-
    cot_prompt(SigName, Inputs, Prompt),
    generate_batch(SigName, chain_of_thought, Rest, RestPrompts).

% ============================================================================ %
% QUERY INTERFACE
% ============================================================================ %

% Main query: get prompt for signature
get_prompt(SigName, Inputs, Prompt) :-
    select_module_type(SigName, predict),
    predict_prompt(SigName, Inputs, Prompt).

get_prompt(SigName, Inputs, Prompt) :-
    select_module_type(SigName, chain_of_thought),
    cot_prompt(SigName, Inputs, Prompt).

% Get full signature info
signature_info(SigName, Info) :-
    signature(SigName, Description, _, _),
    signature_inputs(SigName, Inputs),
    signature_outputs(SigName, Outputs),
    select_module_type(SigName, ModuleType),
    Info = sig_info{
        name: SigName,
        description: Description,
        inputs: Inputs,
        outputs: Outputs,
        module_type: ModuleType
    }.

% ============================================================================ %
% EXAMPLES (for testing, facts would be injected)
% ============================================================================ %

% Example: Runtime would inject these facts:
%
%   signature(sentiment_classification,
%       "Classify the sentiment of the given text.",
%       [text], [sentiment, confidence]).
%
%   input_field(sentiment_classification, text, "Text to analyze", true, none).
%
%   output_field(sentiment_classification, sentiment, enum,
%       [positive, negative, neutral]).
%   output_field(sentiment_classification, confidence, float, range(0.0, 1.0)).
%
% Then query:
%   ?- get_prompt(sentiment_classification, [(text, "I love this!")], Prompt).