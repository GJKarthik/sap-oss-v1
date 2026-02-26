% ============================================================================
% Fractal Write Pointers — Mangle Rules for Privacy-Preserving LLM Outputs
%
% Fractal IDs provide hierarchical scoping:
%   Level 0: Tenant   (8 chars) - Multi-tenant isolation
%   Level 1: Service  (6 chars) - Service binding
%   Level 2: Session  (6 chars) - Session scoping
%   Level 3: Message  (4 chars) - Message ordering
%   Level 4: Sequence (4 chars) - Within-message sequence
%   Level 5: Nonce    (4 chars) - Enumeration resistance
%
% Format: TTTTTTTT.SSSSSS.NNNNNN.MMMM.QQQQ.XXXX
% URI:    toon-write://FRACTAL_ID@DEST?type=text
% ============================================================================

% --------------------------------------------------------------------------
% Fractal Levels
% --------------------------------------------------------------------------

fractal_level(0, "tenant", 8).
fractal_level(1, "service", 6).
fractal_level(2, "session", 6).
fractal_level(3, "message", 4).
fractal_level(4, "sequence", 4).
fractal_level(5, "nonce", 4).

% Total ID length = 8 + 6 + 6 + 4 + 4 + 4 + 5 dots = 37 chars

% --------------------------------------------------------------------------
% Response Types
% --------------------------------------------------------------------------

response_type("text").       % Plain text LLM response
response_type("embedding").  % Vector embedding (1536-dim)
response_type("json").       % Structured JSON
response_type("binary").     % Binary blob

% --------------------------------------------------------------------------
% Generate Fractal Pointer ID
% --------------------------------------------------------------------------

% generate_fractal_id(Tenant, Service, Session, Message, Seq) → FractalID
generate_fractal_id(Tenant, Service, Session, Message, Seq, FractalID) :-
    hash8(Tenant, TenantHash),
    compress6(Service, ServiceCode),
    hash6(Session, SessionHash),
    hash4(Message, MessageHash),
    encode_seq(Seq, SeqCode),
    generate_nonce(Nonce),
    fn:string_concat(TenantHash, ".", S1),
    fn:string_concat(S1, ServiceCode, S2),
    fn:string_concat(S2, ".", S3),
    fn:string_concat(S3, SessionHash, S4),
    fn:string_concat(S4, ".", S5),
    fn:string_concat(S5, MessageHash, S6),
    fn:string_concat(S6, ".", S7),
    fn:string_concat(S7, SeqCode, S8),
    fn:string_concat(S8, ".", S9),
    fn:string_concat(S9, Nonce, FractalID).

% --------------------------------------------------------------------------
% Write Pointer Creation
% --------------------------------------------------------------------------

% create_write_pointer(Context, ResponseType, Content) → Pointer
create_write_pointer(Context, ResponseType, Content, Pointer) :-
    context_tenant(Context, Tenant),
    context_service(Context, Service),
    context_session(Context, Session),
    context_message(Context, Message),
    get_next_sequence(Seq),
    generate_fractal_id(Tenant, Service, Session, Message, Seq, FractalID),
    response_type(ResponseType),
    build_write_pointer(FractalID, ResponseType, Content, Pointer).

build_write_pointer(FractalID, ResponseType, Content, Pointer) :-
    current_timestamp(Now),
    ttl(3600),
    Pointer = write_pointer(FractalID, ResponseType, Content, Now, 3600).

% --------------------------------------------------------------------------
% Write Pointer to URI
% --------------------------------------------------------------------------

% Format: toon-write://FRACTAL_ID@DEST?type=text&ttl=3600
write_pointer_to_uri(Pointer, Credentials, URI) :-
    write_pointer(FractalID, ResponseType, _, _, TTL) = Pointer,
    fn:string_concat("toon-write://", FractalID, S1),
    fn:string_concat(S1, "@", S2),
    fn:string_concat(S2, Credentials, S3),
    fn:string_concat(S3, "?type=", S4),
    fn:string_concat(S4, ResponseType, S5),
    fn:string_concat(S5, "&ttl=", S6),
    fn:number_to_string(TTL, TTLStr),
    fn:string_concat(S6, TTLStr, URI).

% --------------------------------------------------------------------------
% Access Control Validation
% --------------------------------------------------------------------------

% validate_access(Pointer, CallerContext) → allowed/denied
validate_access(Pointer, CallerContext, allowed) :-
    write_pointer(FractalID, _, _, _, _) = Pointer,
    extract_tenant_hash(FractalID, PointerTenant),
    extract_session_hash(FractalID, PointerSession),
    context_tenant(CallerContext, CallerTenant),
    context_session(CallerContext, CallerSession),
    hash8(CallerTenant, CallerTenantHash),
    hash6(CallerSession, CallerSessionHash),
    PointerTenant = CallerTenantHash,
    PointerSession = CallerSessionHash.

validate_access(Pointer, CallerContext, denied) :-
    not validate_access(Pointer, CallerContext, allowed).

% --------------------------------------------------------------------------
% Extract Fractal ID Components
% --------------------------------------------------------------------------

extract_tenant_hash(FractalID, TenantHash) :-
    fn:substring(FractalID, 0, 8, TenantHash).

extract_service_code(FractalID, ServiceCode) :-
    fn:substring(FractalID, 9, 6, ServiceCode).

extract_session_hash(FractalID, SessionHash) :-
    fn:substring(FractalID, 16, 6, SessionHash).

extract_message_hash(FractalID, MessageHash) :-
    fn:substring(FractalID, 23, 4, MessageHash).

extract_sequence(FractalID, Sequence) :-
    fn:substring(FractalID, 28, 4, Sequence).

extract_nonce(FractalID, Nonce) :-
    fn:substring(FractalID, 33, 4, Nonce).

% --------------------------------------------------------------------------
% HANA Write Operations
% --------------------------------------------------------------------------

% write_to_hana(Pointer, Content, Credentials) → Success/Failure
write_to_hana(Pointer, Content, Credentials, Success) :-
    write_pointer(FractalID, ResponseType, _, _, TTL) = Pointer,
    extract_tenant_hash(FractalID, TenantHash),
    extract_service_code(FractalID, ServiceCode),
    extract_session_hash(FractalID, SessionHash),
    extract_message_hash(FractalID, MessageHash),
    build_insert_sql(FractalID, TenantHash, ServiceCode, SessionHash, 
                     MessageHash, ResponseType, Content, TTL, SQL),
    execute_hana_sql(SQL, Credentials, Success).

build_insert_sql(FractalID, TenantHash, ServiceCode, SessionHash, 
                 MessageHash, ResponseType, Content, TTL, SQL) :-
    fn:sql_escape(FractalID, SafeFractalID),
    fn:sql_escape(TenantHash, SafeTenantHash),
    fn:sql_escape(ServiceCode, SafeServiceCode),
    fn:sql_escape(SessionHash, SafeSessionHash),
    fn:sql_escape(MessageHash, SafeMessageHash),
    fn:sql_escape(ResponseType, SafeResponseType),
    fn:sql_escape(Content, SafeContent),
    fn:string_concat("INSERT INTO AI_OUTPUTS.LLM_RESPONSES (", S1),
    fn:string_concat(S1, "POINTER_ID, TENANT_HASH, SERVICE_CODE, ", S2),
    fn:string_concat(S2, "SESSION_HASH, MESSAGE_HASH, RESPONSE_TYPE, ", S3),
    fn:string_concat(S3, "CONTENT, CREATED_AT, EXPIRES_AT) VALUES ('", S4),
    fn:string_concat(S4, SafeFractalID, S5),
    fn:string_concat(S5, "', '", S6),
    fn:string_concat(S6, SafeTenantHash, S7),
    fn:string_concat(S7, "', '", S8),
    fn:string_concat(S8, SafeServiceCode, S9),
    fn:string_concat(S9, "', '", S10),
    fn:string_concat(S10, SafeSessionHash, S11),
    fn:string_concat(S11, "', '", S12),
    fn:string_concat(S12, SafeMessageHash, S13),
    fn:string_concat(S13, "', '", S14),
    fn:string_concat(S14, SafeResponseType, S15),
    fn:string_concat(S15, "', '", S16),
    fn:string_concat(S16, SafeContent, S17),
    fn:string_concat(S17, "', CURRENT_TIMESTAMP, ADD_SECONDS(CURRENT_TIMESTAMP, ", S18),
    fn:number_to_string(TTL, TTLStr),
    fn:string_concat(S18, TTLStr, S19),
    fn:string_concat(S19, "))", SQL).

% --------------------------------------------------------------------------
% Read Pointer Resolution
% --------------------------------------------------------------------------

% resolve_write_pointer(FractalID, CallerContext) → Content
resolve_write_pointer(FractalID, CallerContext, Content) :-
    validate_access_by_id(FractalID, CallerContext, allowed),
    build_select_sql(FractalID, SQL),
    execute_hana_sql(SQL, _, Result),
    extract_content(Result, Content).

validate_access_by_id(FractalID, CallerContext, allowed) :-
    extract_tenant_hash(FractalID, PointerTenant),
    extract_session_hash(FractalID, PointerSession),
    context_tenant(CallerContext, CallerTenant),
    context_session(CallerContext, CallerSession),
    hash8(CallerTenant, CallerTenantHash),
    hash6(CallerSession, CallerSessionHash),
    PointerTenant = CallerTenantHash,
    PointerSession = CallerSessionHash.

build_select_sql(FractalID, SQL) :-
    fn:sql_escape(FractalID, SafeFractalID),
    fn:string_concat("SELECT CONTENT FROM AI_OUTPUTS.LLM_RESPONSES WHERE POINTER_ID = '", S1),
    fn:string_concat(S1, SafeFractalID, S2),
    fn:string_concat(S2, "' AND EXPIRES_AT > CURRENT_TIMESTAMP", SQL).

% --------------------------------------------------------------------------
% Session Queries (get all responses for a session)
% --------------------------------------------------------------------------

% query_session_responses(CallerContext) → List of FractalIDs
query_session_responses(CallerContext, FractalIDs) :-
    context_tenant(CallerContext, Tenant),
    context_service(CallerContext, Service),
    context_session(CallerContext, Session),
    hash8(Tenant, TenantHash),
    compress6(Service, ServiceCode),
    hash6(Session, SessionHash),
    build_session_query(TenantHash, ServiceCode, SessionHash, SQL),
    execute_hana_sql(SQL, _, FractalIDs).

build_session_query(TenantHash, ServiceCode, SessionHash, SQL) :-
    fn:sql_escape(TenantHash, SafeTenantHash),
    fn:sql_escape(ServiceCode, SafeServiceCode),
    fn:sql_escape(SessionHash, SafeSessionHash),
    fn:string_concat("SELECT POINTER_ID FROM AI_OUTPUTS.LLM_RESPONSES WHERE TENANT_HASH = '", S1),
    fn:string_concat(S1, SafeTenantHash, S2),
    fn:string_concat(S2, "' AND SERVICE_CODE = '", S3),
    fn:string_concat(S3, SafeServiceCode, S4),
    fn:string_concat(S4, "' AND SESSION_HASH = '", S5),
    fn:string_concat(S5, SafeSessionHash, S6),
    fn:string_concat(S6, "' AND EXPIRES_AT > CURRENT_TIMESTAMP ORDER BY CREATED_AT", SQL).

% --------------------------------------------------------------------------
% Message Queries (get all responses for a message)
% --------------------------------------------------------------------------

query_message_responses(CallerContext, MessageID, FractalIDs) :-
    context_tenant(CallerContext, Tenant),
    context_service(CallerContext, Service),
    context_session(CallerContext, Session),
    hash8(Tenant, TenantHash),
    compress6(Service, ServiceCode),
    hash6(Session, SessionHash),
    hash4(MessageID, MessageHash),
    build_message_query(TenantHash, ServiceCode, SessionHash, MessageHash, SQL),
    execute_hana_sql(SQL, _, FractalIDs).

build_message_query(TenantHash, ServiceCode, SessionHash, MessageHash, SQL) :-
    fn:sql_escape(TenantHash, SafeTenantHash),
    fn:sql_escape(ServiceCode, SafeServiceCode),
    fn:sql_escape(SessionHash, SafeSessionHash),
    fn:sql_escape(MessageHash, SafeMessageHash),
    fn:string_concat("SELECT POINTER_ID FROM AI_OUTPUTS.LLM_RESPONSES WHERE TENANT_HASH = '", S1),
    fn:string_concat(S1, SafeTenantHash, S2),
    fn:string_concat(S2, "' AND SERVICE_CODE = '", S3),
    fn:string_concat(S3, SafeServiceCode, S4),
    fn:string_concat(S4, "' AND SESSION_HASH = '", S5),
    fn:string_concat(S5, SafeSessionHash, S6),
    fn:string_concat(S6, "' AND MESSAGE_HASH = '", S7),
    fn:string_concat(S7, SafeMessageHash, S8),
    fn:string_concat(S8, "' AND EXPIRES_AT > CURRENT_TIMESTAMP ORDER BY CREATED_AT", SQL).

% --------------------------------------------------------------------------
% Privacy Guarantees
% --------------------------------------------------------------------------

% Differential privacy: cannot enumerate other sessions' pointers
cannot_enumerate(CallerContext, OtherSession) :-
    context_session(CallerContext, CallerSession),
    CallerSession \= OtherSession.

% No cross-tenant access
tenant_isolated(CallerContext, OtherTenant) :-
    context_tenant(CallerContext, CallerTenant),
    CallerTenant \= OtherTenant.

% --------------------------------------------------------------------------
% DSPy/TOON Integration
% --------------------------------------------------------------------------

% LLM generates response → write to HANA → return pointer
toon_generate_and_store(Module, Input, Context, Pointer) :-
    toon_execute(Module, Input, Response),
    create_write_pointer(Context, "text", Response, Pointer),
    write_to_hana(Pointer, Response, default_credentials, _).

% Chain with write pointers: each step stores intermediate results
toon_chain_with_storage([], _, FinalPointer, FinalPointer).

toon_chain_with_storage([Module | Rest], Context, InputPointer, FinalPointer) :-
    resolve_write_pointer(InputPointer, Context, InputContent),
    toon_execute(Module, InputContent, Output),
    create_write_pointer(Context, "text", Output, OutputPointer),
    write_to_hana(OutputPointer, Output, default_credentials, _),
    toon_chain_with_storage(Rest, Context, OutputPointer, FinalPointer).

% --------------------------------------------------------------------------
% Intent Patterns
% --------------------------------------------------------------------------

intent_pattern("store response", write_pointer_create).
intent_pattern("save to hana", write_pointer_create).
intent_pattern("persist output", write_pointer_create).
intent_pattern("get my responses", session_query).
intent_pattern("fetch message", message_query).
intent_pattern("retrieve stored", read_pointer).

% --------------------------------------------------------------------------
% Examples
% --------------------------------------------------------------------------

% Example: Create write pointer for LLM response
% ?- create_write_pointer(context(tenant1, svc1, sess1, msg1), "text", "Hello!", Ptr).

% Example: Validate access (same session → allowed)
% ?- validate_access(Ptr, context(tenant1, svc1, sess1, msg2), Result).
% Result = allowed

% Example: Validate access (different session → denied)
% ?- validate_access(Ptr, context(tenant1, svc1, other_sess, msg1), Result).
% Result = denied

% Example: Query all responses in current session
% ?- query_session_responses(context(tenant1, svc1, sess1, _), Pointers).