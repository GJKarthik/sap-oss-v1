% ============================================================================
% TOON Data Pointers — Mangle Rules for Pass-by-Reference Data Exchange
%
% Instead of passing data in DSPy/TOON messages, services pass pointers
% (URIs) that resolve lazily to data at HANA or SAP Object Store.
%
% URI Schemes:
%   hana-table://SCHEMA.TABLE?$filter=...
%   hana-vector://SCHEMA.TABLE.COLUMN?k=10
%   hana-graph://SCHEMA.WORKSPACE/VERTEX?depth=2
%   sap-obj://bucket/key?format=parquet
%   hdl://container/path/file.parquet
% ============================================================================

% --------------------------------------------------------------------------
% Pointer Type Definitions
% --------------------------------------------------------------------------

toon_pointer_type("hana-table").
toon_pointer_type("hana-vector").
toon_pointer_type("hana-graph").
toon_pointer_type("sap-obj").
toon_pointer_type("hdl").

% --------------------------------------------------------------------------
% HANA Table Pointer Creation
% --------------------------------------------------------------------------

% Create a HANA table pointer
% hana_table_pointer(Schema, Table, Filter, Columns, Credentials) → Pointer
hana_table_pointer(Schema, Table, Filter, Columns, Credentials, Pointer) :-
    fn:string_concat("hana-table://", Schema, S1),
    fn:string_concat(S1, ".", S2),
    fn:string_concat(S2, Table, Location),
    build_query("$filter", Filter, "$select", Columns, Query),
    build_pointer(Location, Query, Credentials, 3600, Pointer).

% Simplified version without filter
hana_table_pointer(Schema, Table, Credentials, Pointer) :-
    hana_table_pointer(Schema, Table, "", "*", Credentials, Pointer).

% --------------------------------------------------------------------------
% HANA Vector Pointer Creation (k-NN Similarity Search)
% --------------------------------------------------------------------------

% Create a HANA vector pointer
% hana_vector_pointer(Schema, Table, VectorCol, K, QueryRef, Credentials) → Pointer
hana_vector_pointer(Schema, Table, VectorCol, K, QueryRef, Credentials, Pointer) :-
    fn:string_concat(Schema, ".", S1),
    fn:string_concat(S1, Table, S2),
    fn:string_concat(S2, ".", S3),
    fn:string_concat(S3, VectorCol, Location),
    fn:string_concat("hana-vector://", Location, URI),
    fn:number_to_string(K, KStr),
    fn:string_concat("k=", KStr, Q1),
    fn:string_concat(Q1, "&query_ref=", Q2),
    fn:string_concat(Q2, QueryRef, Query),
    build_pointer(URI, Query, Credentials, 3600, Pointer).

% --------------------------------------------------------------------------
% HANA Graph Pointer Creation (Graph Traversal)
% --------------------------------------------------------------------------

% Create a HANA graph pointer
% hana_graph_pointer(Schema, Workspace, VertexType, Depth, Direction, Credentials) → Pointer
hana_graph_pointer(Schema, Workspace, VertexType, Depth, Direction, Credentials, Pointer) :-
    fn:string_concat(Schema, ".", S1),
    fn:string_concat(S1, Workspace, S2),
    fn:string_concat(S2, "/", S3),
    fn:string_concat(S3, VertexType, Location),
    fn:string_concat("hana-graph://", Location, URI),
    fn:number_to_string(Depth, DepthStr),
    fn:string_concat("depth=", DepthStr, Q1),
    fn:string_concat(Q1, "&direction=", Q2),
    fn:string_concat(Q2, Direction, Query),
    build_pointer(URI, Query, Credentials, 3600, Pointer).

% --------------------------------------------------------------------------
% SAP Object Store Pointer Creation
% --------------------------------------------------------------------------

% Create a SAP Object Store pointer
% sap_object_pointer(Bucket, Key, Format, Columns, Credentials) → Pointer
sap_object_pointer(Bucket, Key, Format, Columns, Credentials, Pointer) :-
    fn:string_concat(Bucket, "/", S1),
    fn:string_concat(S1, Key, Location),
    fn:string_concat("sap-obj://", Location, URI),
    fn:string_concat("format=", Format, Q1),
    fn:string_concat(Q1, "&columns=", Q2),
    fn:string_concat(Q2, Columns, Query),
    build_pointer(URI, Query, Credentials, 3600, Pointer).

% Simplified version (auto-detect format)
sap_object_pointer(Bucket, Key, Credentials, Pointer) :-
    sap_object_pointer(Bucket, Key, "auto", "*", Credentials, Pointer).

% --------------------------------------------------------------------------
% HANA Data Lake Files Pointer Creation
% --------------------------------------------------------------------------

% Create a HANA Data Lake pointer
% hdl_pointer(Container, Path, Format, Credentials) → Pointer
hdl_pointer(Container, Path, Format, Credentials, Pointer) :-
    fn:string_concat(Container, "/", S1),
    fn:string_concat(S1, Path, Location),
    fn:string_concat("hdl://", Location, URI),
    fn:string_concat("format=", Format, Query),
    build_pointer(URI, Query, Credentials, 3600, Pointer).

% --------------------------------------------------------------------------
% Pointer Resolution Rules
% --------------------------------------------------------------------------

% Resolve any pointer type to its resolution
resolve_pointer(Pointer, Resolution) :-
    pointer_type(Pointer, "hana-table"),
    resolve_hana_table(Pointer, Resolution).

resolve_pointer(Pointer, Resolution) :-
    pointer_type(Pointer, "hana-vector"),
    resolve_hana_vector(Pointer, Resolution).

resolve_pointer(Pointer, Resolution) :-
    pointer_type(Pointer, "hana-graph"),
    resolve_hana_graph(Pointer, Resolution).

resolve_pointer(Pointer, Resolution) :-
    pointer_type(Pointer, "sap-obj"),
    resolve_sap_object(Pointer, Resolution).

resolve_pointer(Pointer, Resolution) :-
    pointer_type(Pointer, "hdl"),
    resolve_hdl(Pointer, Resolution).

% --------------------------------------------------------------------------
% HANA Table Resolution → SQL
% --------------------------------------------------------------------------

resolve_hana_table(Pointer, SQL) :-
    pointer_location(Pointer, Location),
    pointer_query(Pointer, Query),
    parse_schema_table(Location, Schema, Table),
    parse_odata_filter(Query, WhereClause),
    parse_odata_select(Query, Columns),
    build_sql_select(Schema, Table, Columns, WhereClause, SQL).

build_sql_select(Schema, Table, Columns, WhereClause, SQL) :-
    fn:validate_identifier(Schema),
    fn:validate_identifier(Table),
    fn:string_concat("SELECT ", Columns, S1),
    fn:string_concat(S1, " FROM \"", S2),
    fn:string_concat(S2, Schema, S3),
    fn:string_concat(S3, "\".\"", S4),
    fn:string_concat(S4, Table, S5),
    fn:string_concat(S5, "\"", S6),
    fn:string_concat(S6, " WHERE ", S7),
    fn:string_concat(S7, WhereClause, SQL).

% --------------------------------------------------------------------------
% HANA Vector Resolution → Similarity SQL
% --------------------------------------------------------------------------

resolve_hana_vector(Pointer, SQL) :-
    pointer_location(Pointer, Location),
    pointer_query(Pointer, Query),
    parse_schema_table_column(Location, Schema, Table, VectorCol),
    parse_k(Query, K),
    parse_query_ref(Query, QueryRef),
    build_vector_sql(Schema, Table, VectorCol, K, QueryRef, SQL).

build_vector_sql(Schema, Table, VectorCol, K, QueryRef, SQL) :-
    fn:validate_identifier(Schema),
    fn:validate_identifier(Table),
    fn:validate_identifier(VectorCol),
    fn:sql_escape(QueryRef, SafeQueryRef),
    fn:string_concat("SELECT TOP ", K, S1),
    fn:string_concat(S1, " *, COSINE_SIMILARITY(\"", S2),
    fn:string_concat(S2, VectorCol, S3),
    fn:string_concat(S3, "\", (SELECT \"", S4),
    fn:string_concat(S4, VectorCol, S5),
    fn:string_concat(S5, "\" FROM \"", S6),
    fn:string_concat(S6, Schema, S7),
    fn:string_concat(S7, "\".\"", S8),
    fn:string_concat(S8, Table, S9),
    fn:string_concat(S9, "\" WHERE ID = '", S10),
    fn:string_concat(S10, SafeQueryRef, S11),
    fn:string_concat(S11, "')) AS similarity FROM \"", S12),
    fn:string_concat(S12, Schema, S13),
    fn:string_concat(S13, "\".\"", S14),
    fn:string_concat(S14, Table, S15),
    fn:string_concat(S15, "\" ORDER BY similarity DESC", SQL).

% --------------------------------------------------------------------------
% HANA Graph Resolution → Graph Query
% --------------------------------------------------------------------------

resolve_hana_graph(Pointer, GraphQL) :-
    pointer_location(Pointer, Location),
    pointer_query(Pointer, Query),
    parse_schema_workspace_vertex(Location, Schema, Workspace, VertexType),
    parse_depth(Query, Depth),
    parse_direction(Query, Direction),
    build_graph_query(Schema, Workspace, VertexType, Depth, Direction, GraphQL).

build_graph_query(Schema, Workspace, VertexType, Depth, Direction, GraphQL) :-
    fn:validate_identifier(Schema),
    fn:validate_identifier(Workspace),
    fn:validate_identifier(VertexType),
    fn:string_concat("GRAPH_WORKSPACE \"", Schema, S1),
    fn:string_concat(S1, "\".\"", S2),
    fn:string_concat(S2, Workspace, S3),
    fn:string_concat(S3, "\" MATCH (n:", S4),
    fn:string_concat(S4, VertexType, S5),
    fn:string_concat(S5, ")", S6),
    build_traversal_pattern(Depth, Direction, Pattern),
    fn:string_concat(S6, Pattern, S7),
    fn:string_concat(S7, " RETURN n, e, m", GraphQL).

% --------------------------------------------------------------------------
% SAP Object Store Resolution → Presigned URL
% --------------------------------------------------------------------------

resolve_sap_object(Pointer, PresignedURL) :-
    pointer_location(Pointer, Location),
    pointer_credentials(Pointer, CredRef),
    pointer_ttl(Pointer, TTL),
    generate_s3_presigned_url(Location, CredRef, TTL, PresignedURL).

% --------------------------------------------------------------------------
% HANA Data Lake Resolution → Presigned URL
% --------------------------------------------------------------------------

resolve_hdl(Pointer, PresignedURL) :-
    pointer_location(Pointer, Location),
    pointer_credentials(Pointer, CredRef),
    pointer_ttl(Pointer, TTL),
    generate_hdl_url(Location, CredRef, TTL, PresignedURL).

% --------------------------------------------------------------------------
% Pointer Validation
% --------------------------------------------------------------------------

valid_pointer(Pointer) :-
    pointer_type(Pointer, Type),
    toon_pointer_type(Type),
    pointer_ttl(Pointer, TTL),
    TTL > 0,
    pointer_created(Pointer, Created),
    current_timestamp(Now),
    Elapsed = Now - Created,
    Elapsed < TTL.

expired_pointer(Pointer) :-
    pointer_ttl(Pointer, TTL),
    pointer_created(Pointer, Created),
    current_timestamp(Now),
    Elapsed = Now - Created,
    Elapsed >= TTL.

% --------------------------------------------------------------------------
% Helper Rules
% --------------------------------------------------------------------------

% Build a pointer structure
build_pointer(URI, Query, Credentials, TTL, Pointer) :-
    current_timestamp(Now),
    generate_pointer_id(ID),
    Pointer = pointer(URI, Query, Credentials, TTL, Now, ID).

% --------------------------------------------------------------------------
% Built-in Predicate Implementations
% --------------------------------------------------------------------------

% Get current Unix timestamp (seconds since epoch)
current_timestamp(Now) :-
    fn:now(Now).

% Generate a unique pointer ID (UUID-style)
generate_pointer_id(ID) :-
    fn:uuid(ID).

% Extract URI scheme (text before "://")
extract_scheme(URI, Scheme) :-
    fn:string_index_of(URI, "://", Idx),
    fn:substring(URI, 0, Idx, Scheme).

% Extract URI location (text after "://" up to "?" or end)
extract_location(URI, Location) :-
    fn:string_index_of(URI, "://", SchemeEnd),
    SchemeEnd3 = SchemeEnd + 3,
    fn:substring(URI, SchemeEnd3, Location0),
    extract_until_query(Location0, Location).

extract_until_query(S, Location) :-
    fn:string_index_of(S, "?", Idx),
    fn:substring(S, 0, Idx, Location).
extract_until_query(S, S) :-
    \+ fn:string_contains(S, "?").

% Extract pointer components from structured term
pointer_type(pointer(URI, _, _, _, _, _), Type) :-
    extract_scheme(URI, Type).

pointer_location(pointer(URI, _, _, _, _, _), Location) :-
    extract_location(URI, Location).

pointer_query(pointer(_, Query, _, _, _, _), Query).

pointer_credentials(pointer(_, _, Credentials, _, _, _), Credentials).

pointer_ttl(pointer(_, _, _, TTL, _, _), TTL).

pointer_created(pointer(_, _, _, _, Created, _), Created).

pointer_id(pointer(_, _, _, _, _, ID), ID).

% --------------------------------------------------------------------------
% OData to SQL Conversion
% --------------------------------------------------------------------------

% OData to SQL operator conversion
odata_to_sql(" eq ", " = ").
odata_to_sql(" ne ", " <> ").
odata_to_sql(" lt ", " < ").
odata_to_sql(" le ", " <= ").
odata_to_sql(" gt ", " > ").
odata_to_sql(" ge ", " >= ").
odata_to_sql(" and ", " AND ").
odata_to_sql(" or ", " OR ").

% Parse $filter from OData query string to SQL WHERE clause
parse_odata_filter(Query, WhereClause) :-
    fn:string_index_of(Query, "$filter=", Idx),
    FilterStart = Idx + 8,
    fn:substring(Query, FilterStart, FilterValue),
    replace_odata_ops(FilterValue, WhereClause).

% Replace OData operators with SQL equivalents
replace_odata_ops(Input, Output) :-
    odata_to_sql(OdataOp, SqlOp),
    fn:string_contains(Input, OdataOp),
    fn:string_replace(Input, OdataOp, SqlOp, Replaced),
    replace_odata_ops(Replaced, Output).
replace_odata_ops(Input, Input) :-
    \+ (odata_to_sql(OdataOp, _), fn:string_contains(Input, OdataOp)).

% Parse $select from OData query string
parse_odata_select(Query, Columns) :-
    fn:string_index_of(Query, "$select=", Idx),
    SelectStart = Idx + 8,
    fn:substring(Query, SelectStart, Columns).
parse_odata_select(Query, "*") :-
    \+ fn:string_contains(Query, "$select=").

% Parse schema.table from location string
parse_schema_table(Location, Schema, Table) :-
    fn:string_index_of(Location, ".", Idx),
    fn:substring(Location, 0, Idx, Schema),
    Idx1 = Idx + 1,
    fn:substring(Location, Idx1, Table).

% Parse schema.table.column from location string
parse_schema_table_column(Location, Schema, Table, Column) :-
    fn:string_index_of(Location, ".", Idx1),
    fn:substring(Location, 0, Idx1, Schema),
    Rest1Start = Idx1 + 1,
    fn:substring(Location, Rest1Start, Rest1),
    fn:string_index_of(Rest1, ".", Idx2),
    fn:substring(Rest1, 0, Idx2, Table),
    Rest2Start = Idx2 + 1,
    fn:substring(Rest1, Rest2Start, Column).

% Parse schema.workspace/vertex from location string
parse_schema_workspace_vertex(Location, Schema, Workspace, VertexType) :-
    parse_schema_table(Location, Schema, Rest),
    fn:string_index_of(Rest, "/", SlashIdx),
    fn:substring(Rest, 0, SlashIdx, Workspace),
    VtStart = SlashIdx + 1,
    fn:substring(Rest, VtStart, VertexType).

% Parse k and query_ref from vector query string
parse_k(Query, K) :-
    fn:string_index_of(Query, "k=", Idx),
    KStart = Idx + 2,
    fn:substring(Query, KStart, KStr),
    fn:string_to_number(KStr, K).

parse_query_ref(Query, QueryRef) :-
    fn:string_index_of(Query, "query_ref=", Idx),
    RefStart = Idx + 10,
    fn:substring(Query, RefStart, QueryRef).

% Parse depth and direction from graph query string
parse_depth(Query, Depth) :-
    fn:string_index_of(Query, "depth=", Idx),
    DStart = Idx + 6,
    fn:substring(Query, DStart, DStr),
    fn:string_to_number(DStr, Depth).

parse_direction(Query, Direction) :-
    fn:string_index_of(Query, "direction=", Idx),
    DirStart = Idx + 10,
    fn:substring(Query, DirStart, Direction).

% Build traversal pattern for graph queries
build_traversal_pattern(0, _, "").
build_traversal_pattern(Depth, "outgoing", Pattern) :-
    Depth > 0,
    D1 = Depth - 1,
    build_traversal_pattern(D1, "outgoing", Rest),
    fn:string_concat("-[e]->(m)", Rest, Pattern).
build_traversal_pattern(Depth, "incoming", Pattern) :-
    Depth > 0,
    D1 = Depth - 1,
    build_traversal_pattern(D1, "incoming", Rest),
    fn:string_concat("<-[e]-(m)", Rest, Pattern).
build_traversal_pattern(Depth, "any", Pattern) :-
    Depth > 0,
    D1 = Depth - 1,
    build_traversal_pattern(D1, "any", Rest),
    fn:string_concat("-[e]-(m)", Rest, Pattern).

% Generate S3 presigned URL (delegates to external function)
generate_s3_presigned_url(Location, CredRef, TTL, URL) :-
    fn:s3_presign(Location, CredRef, TTL, URL).

% Generate HDL presigned URL (delegates to external function)
generate_hdl_url(Location, CredRef, TTL, URL) :-
    fn:hdl_presign(Location, CredRef, TTL, URL).

% --------------------------------------------------------------------------
% DSPy/TOON Integration Patterns
% --------------------------------------------------------------------------

% TOON module receives pointer, resolves, and processes
toon_process_pointer(Module, Pointer, Result) :-
    valid_pointer(Pointer),
    resolve_pointer(Pointer, Resolution),
    toon_execute(Module, Resolution, Result).

% Execute a TOON module with resolved data
% Delegates to the external TOON/DSPy runtime via FFI
toon_execute(Module, Resolution, Result) :-
    fn:toon_run(Module, Resolution, Result).

% Chain of pointers (data pipeline)
toon_chain_pointers([Pointer], Result) :-
    toon_process_pointer(default_module, Pointer, Result).

toon_chain_pointers([Pointer | Rest], FinalResult) :-
    toon_process_pointer(default_module, Pointer, IntermediateResult),
    create_result_pointer(IntermediateResult, NextPointer),
    toon_chain_pointers([NextPointer | Rest], FinalResult).

% Create a pointer from an intermediate result (wraps result as sap-obj pointer)
create_result_pointer(IntermediateResult, Pointer) :-
    fn:store_result(IntermediateResult, Bucket, Key),
    sap_object_pointer(Bucket, Key, "auto", "*", "INTERNAL", Pointer).

% GPU-accelerated pointer resolution
gpu_resolve_pointer(Pointer, GpuTensor) :-
    resolve_pointer(Pointer, Resolution),
    load_to_gpu(Resolution, GpuTensor).

% Load resolved data to GPU memory (delegates to external CUDA function)
load_to_gpu(Resolution, GpuTensor) :-
    fn:cuda_load(Resolution, GpuTensor).

% --------------------------------------------------------------------------
% Intent Patterns for Natural Language Pointer Commands
% --------------------------------------------------------------------------

intent_pattern("create pointer to", pointer_create).
intent_pattern("point at", pointer_create).
intent_pattern("reference data in", pointer_create).
intent_pattern("resolve pointer", pointer_resolve).
intent_pattern("fetch from pointer", pointer_resolve).
intent_pattern("load pointer to gpu", pointer_gpu_load).

% Data source keywords
data_source_keyword("hana table", "hana-table").
data_source_keyword("vector column", "hana-vector").
data_source_keyword("graph workspace", "hana-graph").
data_source_keyword("object store", "sap-obj").
data_source_keyword("data lake", "hdl").
data_source_keyword("parquet", "sap-obj").
data_source_keyword("embeddings", "hana-vector").

% --------------------------------------------------------------------------
% Examples
% --------------------------------------------------------------------------

% Example: Create a pointer to SALES.ORDERS with filter
% ?- hana_table_pointer("SALES", "ORDERS", "YEAR eq 2024", "ORDER_ID,AMOUNT", "HANA_PROD", Ptr).

% Example: Create a vector search pointer
% ?- hana_vector_pointer("EMBEDDINGS", "DOCS", "VECTOR", 10, "doc_123", "HANA_VECTOR", Ptr).

% Example: Create an object store pointer
% ?- sap_object_pointer("ai-models", "weights/model.parquet", "parquet", "*", "OBJECT_STORE", Ptr).

% Example: Resolve a pointer to SQL/URL
% ?- resolve_pointer(Ptr, Resolution).

% Example: Check if pointer is valid
% ?- valid_pointer(Ptr).