// ============================================================================
// HANA Connector Schema - Shared contract for all BTP services
// ============================================================================
// This defines the interface contract for HANA connections.
// Each service generates its own Zig implementation from this schema.

// --- Connection Configuration ---
Decl hana_config(
    service_id: String,          // BTP service using this config
    host: String,                // HANA host
    port: i32,                   // HANA port (typically 443)
    schema: String,              // Default schema
    credential_ref: String       // BTP destination or secret name
).

// --- Connection State ---
Decl hana_connection(
    connection_id: String,
    service_id: String,
    status: String,              // connected, disconnected, error
    created_at: i64,
    last_used_at: i64
).

// ============================================================================
// Database Schema Operations - Full CRUD
// ============================================================================

// --- Schema Definition ---
Decl hana_schema(
    schema_id: String,
    schema_name: String,
    owner: String,
    created_at: i64,
    comment: String
).

// --- Schema Privilege ---
Decl hana_schema_privilege(
    privilege_id: String,
    schema_name: String,
    grantee: String,             // User or role name
    privilege_type: String,      // SELECT, INSERT, UPDATE, DELETE, EXECUTE, CREATE ANY, etc.
    is_grantable: i32,           // 1 = WITH GRANT OPTION
    granted_at: i64
).

// CREATE: Create schema
Decl hana_schema_create(
    request_id: String,
    service_id: String,
    schema_name: String,
    owner: String,               // Optional, defaults to current user
    comment: String,
    requested_at: i64
).

// READ: List schemas
Decl hana_schema_list(
    request_id: String,
    service_id: String,
    name_pattern: String,        // LIKE pattern
    owner_filter: String,
    requested_at: i64
).

// READ: Get schema metadata
Decl hana_schema_get(
    request_id: String,
    service_id: String,
    schema_name: String,
    include_objects: i32,        // 1 = include tables, views, etc.
    include_privileges: i32,
    requested_at: i64
).

// UPDATE: Change schema owner
Decl hana_schema_change_owner(
    request_id: String,
    service_id: String,
    schema_name: String,
    new_owner: String,
    requested_at: i64
).

// UPDATE: Grant privilege on schema
Decl hana_schema_grant(
    request_id: String,
    service_id: String,
    schema_name: String,
    grantee: String,
    privilege_type: String,
    with_grant_option: i32,
    requested_at: i64
).

// UPDATE: Revoke privilege on schema
Decl hana_schema_revoke(
    request_id: String,
    service_id: String,
    schema_name: String,
    grantee: String,
    privilege_type: String,
    cascade: i32,                // 1 = revoke from dependent grantees
    requested_at: i64
).

// DELETE: Drop schema
Decl hana_schema_drop(
    request_id: String,
    service_id: String,
    schema_name: String,
    cascade: i32,                // 1 = drop all objects in schema
    requested_at: i64
).

// Schema operation result
Decl hana_schema_operation_result(
    request_id: String,
    operation: String,
    status: String,
    schema_name: String,
    duration_ms: i64,
    error_message: String
).

// ============================================================================
// View Operations - Full CRUD
// ============================================================================

// --- View Definition ---
Decl hana_view(
    view_id: String,
    schema: String,
    view_name: String,
    view_type: String,           // standard, materialized, calculation
    definition: String,          // SQL SELECT statement
    is_valid: i32,               // 1 = valid, 0 = invalid (broken dependency)
    created_at: i64,
    modified_at: i64
).

// --- View Column ---
Decl hana_view_column(
    column_id: String,
    view_id: String,
    column_name: String,
    data_type: String,
    ordinal_position: i32
).

// CREATE: Create view
Decl hana_view_create(
    request_id: String,
    service_id: String,
    schema: String,
    view_name: String,
    view_type: String,
    definition: String,          // SELECT statement
    or_replace: i32,             // 1 = CREATE OR REPLACE
    requested_at: i64
).

// CREATE: Create materialized view
Decl hana_view_create_materialized(
    request_id: String,
    service_id: String,
    schema: String,
    view_name: String,
    definition: String,
    refresh_type: String,        // manual, auto
    refresh_interval: i32,       // In seconds (for auto)
    requested_at: i64
).

// READ: Get view definition
Decl hana_view_get(
    request_id: String,
    service_id: String,
    schema: String,
    view_name: String,
    include_columns: i32,
    include_dependencies: i32,
    requested_at: i64
).

// READ: List views
Decl hana_view_list(
    request_id: String,
    service_id: String,
    schema: String,
    name_pattern: String,
    view_type_filter: String,
    requested_at: i64
).

// UPDATE: Alter view
Decl hana_view_alter(
    request_id: String,
    service_id: String,
    view_id: String,
    new_definition: String,
    requested_at: i64
).

// UPDATE: Refresh materialized view
Decl hana_view_refresh(
    request_id: String,
    service_id: String,
    view_id: String,
    full_refresh: i32,           // 1 = full, 0 = incremental
    requested_at: i64
).

// DELETE: Drop view
Decl hana_view_drop(
    request_id: String,
    service_id: String,
    view_id: String,
    cascade: i32,
    requested_at: i64
).

// View operation result
Decl hana_view_operation_result(
    request_id: String,
    operation: String,
    status: String,
    view_id: String,
    duration_ms: i64,
    error_message: String
).

// ============================================================================
// Sequence Operations - Full CRUD
// ============================================================================

// --- Sequence Definition ---
Decl hana_sequence(
    sequence_id: String,
    schema: String,
    sequence_name: String,
    start_value: i64,
    increment_by: i64,
    min_value: i64,
    max_value: i64,
    cycle: i32,                  // 1 = CYCLE, 0 = NO CYCLE
    cache_size: i32,
    current_value: i64,
    created_at: i64
).

// CREATE: Create sequence
Decl hana_sequence_create(
    request_id: String,
    service_id: String,
    schema: String,
    sequence_name: String,
    start_value: i64,
    increment_by: i64,
    min_value: i64,
    max_value: i64,
    cycle: i32,
    cache_size: i32,
    requested_at: i64
).

// READ: Get sequence metadata
Decl hana_sequence_get(
    request_id: String,
    service_id: String,
    schema: String,
    sequence_name: String,
    requested_at: i64
).

// READ: List sequences
Decl hana_sequence_list(
    request_id: String,
    service_id: String,
    schema: String,
    name_pattern: String,
    requested_at: i64
).

// READ: Get next value
Decl hana_sequence_nextval(
    request_id: String,
    service_id: String,
    sequence_id: String,
    count: i32,                  // Number of values to fetch
    requested_at: i64
).

// READ: Get current value
Decl hana_sequence_currval(
    request_id: String,
    service_id: String,
    sequence_id: String,
    requested_at: i64
).

// UPDATE: Alter sequence
Decl hana_sequence_alter(
    request_id: String,
    service_id: String,
    sequence_id: String,
    new_increment: i64,
    new_min: i64,
    new_max: i64,
    new_cycle: i32,
    new_cache: i32,
    requested_at: i64
).

// UPDATE: Reset sequence
Decl hana_sequence_reset(
    request_id: String,
    service_id: String,
    sequence_id: String,
    restart_with: i64,
    requested_at: i64
).

// DELETE: Drop sequence
Decl hana_sequence_drop(
    request_id: String,
    service_id: String,
    sequence_id: String,
    requested_at: i64
).

// Sequence operation result
Decl hana_sequence_operation_result(
    request_id: String,
    operation: String,
    status: String,
    value: i64,                  // For nextval/currval
    duration_ms: i64,
    error_message: String
).

// ============================================================================
// Synonym Operations - Full CRUD
// ============================================================================

// --- Synonym Definition ---
Decl hana_synonym(
    synonym_id: String,
    schema: String,
    synonym_name: String,
    target_schema: String,
    target_object: String,
    target_type: String,         // TABLE, VIEW, PROCEDURE, FUNCTION, SEQUENCE
    is_public: i32,              // 1 = PUBLIC synonym
    created_at: i64
).

// CREATE: Create synonym
Decl hana_synonym_create(
    request_id: String,
    service_id: String,
    schema: String,              // Empty for PUBLIC
    synonym_name: String,
    target_schema: String,
    target_object: String,
    is_public: i32,
    or_replace: i32,
    requested_at: i64
).

// READ: Get synonym
Decl hana_synonym_get(
    request_id: String,
    service_id: String,
    schema: String,
    synonym_name: String,
    requested_at: i64
).

// READ: List synonyms
Decl hana_synonym_list(
    request_id: String,
    service_id: String,
    schema: String,
    name_pattern: String,
    target_schema_filter: String,
    requested_at: i64
).

// DELETE: Drop synonym
Decl hana_synonym_drop(
    request_id: String,
    service_id: String,
    synonym_id: String,
    requested_at: i64
).

// Synonym operation result
Decl hana_synonym_operation_result(
    request_id: String,
    operation: String,
    status: String,
    synonym_id: String,
    duration_ms: i64,
    error_message: String
).

// ============================================================================
// Stored Procedure Operations - Full CRUD
// ============================================================================

// --- Procedure Definition ---
Decl hana_procedure(
    procedure_id: String,
    schema: String,
    procedure_name: String,
    language: String,            // SQLSCRIPT, R, LLANG
    security_mode: String,       // DEFINER, INVOKER
    is_read_only: i32,
    parameters: String,          // JSON array of {name, type, mode: IN/OUT/INOUT}
    body_hash: String,           // Hash of procedure body for change detection
    created_at: i64,
    modified_at: i64
).

// --- Procedure Parameter ---
Decl hana_procedure_param(
    param_id: String,
    procedure_id: String,
    param_name: String,
    data_type: String,
    param_mode: String,          // IN, OUT, INOUT
    ordinal_position: i32,
    default_value: String
).

// CREATE: Create procedure
Decl hana_procedure_create(
    request_id: String,
    service_id: String,
    schema: String,
    procedure_name: String,
    language: String,
    security_mode: String,
    is_read_only: i32,
    parameters_ref: String,      // TOON pointer to param definitions
    body: String,                // Procedure body
    or_replace: i32,
    requested_at: i64
).

// READ: Get procedure definition
Decl hana_procedure_get(
    request_id: String,
    service_id: String,
    schema: String,
    procedure_name: String,
    include_body: i32,
    include_dependencies: i32,
    requested_at: i64
).

// READ: List procedures
Decl hana_procedure_list(
    request_id: String,
    service_id: String,
    schema: String,
    name_pattern: String,
    language_filter: String,
    requested_at: i64
).

// EXECUTE: Call procedure
Decl hana_procedure_call(
    request_id: String,
    service_id: String,
    procedure_id: String,
    input_params: String,        // JSON object of param:value
    requested_at: i64
).

// EXECUTE: Call result
Decl hana_procedure_result(
    request_id: String,
    output_params: String,       // JSON object of OUT param values
    result_sets_ref: String,     // TOON pointer to result sets
    duration_ms: i64,
    status: String
).

// UPDATE: Alter procedure
Decl hana_procedure_alter(
    request_id: String,
    service_id: String,
    procedure_id: String,
    new_body: String,
    requested_at: i64
).

// DELETE: Drop procedure
Decl hana_procedure_drop(
    request_id: String,
    service_id: String,
    procedure_id: String,
    requested_at: i64
).

// Procedure operation result
Decl hana_procedure_operation_result(
    request_id: String,
    operation: String,
    status: String,
    procedure_id: String,
    duration_ms: i64,
    error_message: String
).

// ============================================================================
// Function Operations - Full CRUD
// ============================================================================

// --- Function Definition ---
Decl hana_function(
    function_id: String,
    schema: String,
    function_name: String,
    language: String,            // SQLSCRIPT, R, LLANG
    return_type: String,         // Return data type
    is_deterministic: i32,       // 1 = DETERMINISTIC
    security_mode: String,       // DEFINER, INVOKER
    parameters: String,          // JSON array of {name, type}
    body_hash: String,
    created_at: i64,
    modified_at: i64
).

// --- Function Parameter ---
Decl hana_function_param(
    param_id: String,
    function_id: String,
    param_name: String,
    data_type: String,
    ordinal_position: i32,
    default_value: String
).

// CREATE: Create function
Decl hana_function_create(
    request_id: String,
    service_id: String,
    schema: String,
    function_name: String,
    language: String,
    return_type: String,
    is_deterministic: i32,
    security_mode: String,
    parameters_ref: String,      // TOON pointer to param definitions
    body: String,
    or_replace: i32,
    requested_at: i64
).

// READ: Get function definition
Decl hana_function_get(
    request_id: String,
    service_id: String,
    schema: String,
    function_name: String,
    include_body: i32,
    requested_at: i64
).

// READ: List functions
Decl hana_function_list(
    request_id: String,
    service_id: String,
    schema: String,
    name_pattern: String,
    language_filter: String,
    requested_at: i64
).

// EXECUTE: Call function (scalar)
Decl hana_function_call(
    request_id: String,
    service_id: String,
    function_id: String,
    input_params: String,        // JSON object of param:value
    requested_at: i64
).

// EXECUTE: Function result
Decl hana_function_result(
    request_id: String,
    return_value: String,        // Returned value (as string)
    duration_ms: i64,
    status: String
).

// UPDATE: Alter function
Decl hana_function_alter(
    request_id: String,
    service_id: String,
    function_id: String,
    new_body: String,
    requested_at: i64
).

// DELETE: Drop function
Decl hana_function_drop(
    request_id: String,
    service_id: String,
    function_id: String,
    requested_at: i64
).

// Function operation result
Decl hana_function_operation_result(
    request_id: String,
    operation: String,
    status: String,
    function_id: String,
    duration_ms: i64,
    error_message: String
).

// --- Query Execution ---
Decl hana_query(
    query_id: String,
    connection_id: String,
    sql: String,
    parameters: String,          // JSON array of params
    executed_at: i64
).

Decl hana_result(
    query_id: String,
    row_count: i32,
    columns: String,             // JSON array of column names
    duration_ms: i64,
    status: String               // success, error, timeout
).

// ============================================================================
// Table Schema Operations - DDL (Full CRUD)
// ============================================================================

// --- Table Definition ---
Decl hana_table(
    table_id: String,
    schema: String,
    table_name: String,
    table_type: String,          // column, row, virtual, global_temporary
    storage_type: String,        // in-memory, extended, disk
    partition_spec: String,      // JSON partition definition
    created_at: i64
).

// --- Column Definition ---
Decl hana_column(
    column_id: String,
    table_id: String,
    column_name: String,
    data_type: String,           // VARCHAR, INTEGER, DECIMAL, TIMESTAMP, etc.
    length: i32,
    precision: i32,
    scale: i32,
    is_nullable: i32,
    default_value: String,
    is_primary_key: i32,
    ordinal_position: i32
).

// --- Index Definition ---
Decl hana_index(
    index_id: String,
    table_id: String,
    index_name: String,
    index_type: String,          // btree, cpbtree, inverted
    columns: String,             // JSON array of column names
    is_unique: i32
).

// --- Constraint Definition ---
Decl hana_constraint(
    constraint_id: String,
    table_id: String,
    constraint_name: String,
    constraint_type: String,     // primary_key, unique, foreign_key, check
    columns: String,             // JSON array of columns
    reference_table: String,     // For foreign key
    reference_columns: String,   // For foreign key
    check_expression: String     // For check constraint
).

// CREATE: Create table
Decl hana_table_create(
    request_id: String,
    service_id: String,
    schema: String,
    table_name: String,
    columns_ref: String,         // TOON pointer to column definitions JSON
    table_type: String,
    storage_type: String,
    partition_spec: String,
    requested_at: i64
).

// CREATE: Add column to existing table
Decl hana_table_add_column(
    request_id: String,
    service_id: String,
    table_id: String,
    column_name: String,
    data_type: String,
    length: i32,
    is_nullable: i32,
    default_value: String,
    requested_at: i64
).

// CREATE: Create index
Decl hana_table_create_index(
    request_id: String,
    service_id: String,
    table_id: String,
    index_name: String,
    index_type: String,
    columns: String,
    is_unique: i32,
    requested_at: i64
).

// CREATE: Add constraint
Decl hana_table_add_constraint(
    request_id: String,
    service_id: String,
    table_id: String,
    constraint_name: String,
    constraint_type: String,
    columns: String,
    reference_table: String,
    reference_columns: String,
    check_expression: String,
    requested_at: i64
).

// READ: Get table metadata
Decl hana_table_get(
    request_id: String,
    service_id: String,
    schema: String,
    table_name: String,
    include_columns: i32,
    include_indexes: i32,
    include_constraints: i32,
    include_statistics: i32,
    requested_at: i64
).

// READ: List tables in schema
Decl hana_table_list(
    request_id: String,
    service_id: String,
    schema: String,
    name_pattern: String,        // LIKE pattern
    table_type_filter: String,
    requested_at: i64
).

// UPDATE: Modify column
Decl hana_table_alter_column(
    request_id: String,
    service_id: String,
    table_id: String,
    column_name: String,
    new_data_type: String,
    new_length: i32,
    new_nullable: i32,
    new_default: String,
    requested_at: i64
).

// UPDATE: Rename table
Decl hana_table_rename(
    request_id: String,
    service_id: String,
    table_id: String,
    new_name: String,
    requested_at: i64
).

// DELETE: Drop column
Decl hana_table_drop_column(
    request_id: String,
    service_id: String,
    table_id: String,
    column_name: String,
    requested_at: i64
).

// DELETE: Drop index
Decl hana_table_drop_index(
    request_id: String,
    service_id: String,
    index_id: String,
    requested_at: i64
).

// DELETE: Drop constraint
Decl hana_table_drop_constraint(
    request_id: String,
    service_id: String,
    constraint_id: String,
    requested_at: i64
).

// DELETE: Drop table
Decl hana_table_drop(
    request_id: String,
    service_id: String,
    table_id: String,
    cascade: i32,                // 1 = drop dependent objects
    requested_at: i64
).

// DELETE: Truncate table (remove all rows)
Decl hana_table_truncate(
    request_id: String,
    service_id: String,
    table_id: String,
    requested_at: i64
).

// Table DDL operation result
Decl hana_table_ddl_result(
    request_id: String,
    operation: String,           // create, alter, drop, truncate
    status: String,
    object_id: String,
    duration_ms: i64,
    error_message: String
).

// ============================================================================
// Table Data Operations - DML (Full CRUD for Rows)
// ============================================================================

// CREATE: Insert single row
Decl hana_row_insert(
    request_id: String,
    service_id: String,
    table_id: String,
    columns: String,             // JSON array of column names
    values: String,              // JSON array of values
    requested_at: i64
).

// CREATE: Batch insert rows
Decl hana_row_batch_insert(
    batch_id: String,
    service_id: String,
    table_id: String,
    columns: String,             // JSON array of column names
    data_ref: String,            // TOON pointer to row data (Arrow/Parquet)
    row_count: i32,
    requested_at: i64
).

// CREATE: Insert from SELECT
Decl hana_row_insert_select(
    request_id: String,
    service_id: String,
    target_table: String,
    target_columns: String,
    source_query: String,        // SELECT statement
    requested_at: i64
).

// CREATE: Upsert (MERGE)
Decl hana_row_upsert(
    request_id: String,
    service_id: String,
    table_id: String,
    key_columns: String,         // JSON array of key columns
    data_columns: String,        // JSON array of data columns
    values: String,              // JSON array of values
    requested_at: i64
).

// CREATE: Batch upsert
Decl hana_row_batch_upsert(
    batch_id: String,
    service_id: String,
    table_id: String,
    key_columns: String,
    data_columns: String,
    data_ref: String,            // TOON pointer to batch data
    row_count: i32,
    requested_at: i64
).

// READ: Select rows with filter
Decl hana_row_select(
    request_id: String,
    service_id: String,
    table_id: String,
    columns: String,             // JSON array or "*"
    where_clause: String,
    order_by: String,
    limit: i32,
    offset: i32,
    requested_at: i64
).

// READ: Select with join
Decl hana_row_select_join(
    request_id: String,
    service_id: String,
    tables: String,              // JSON array of {table, alias}
    join_conditions: String,     // JSON array of join specs
    columns: String,
    where_clause: String,
    order_by: String,
    limit: i32,
    requested_at: i64
).

// READ: Select aggregation
Decl hana_row_aggregate(
    request_id: String,
    service_id: String,
    table_id: String,
    group_by: String,            // JSON array of columns
    aggregations: String,        // JSON array of {column, function}
    where_clause: String,
    having_clause: String,
    requested_at: i64
).

// READ: Get row by primary key
Decl hana_row_get(
    request_id: String,
    service_id: String,
    table_id: String,
    key_values: String,          // JSON object of key column:value
    columns: String,             // JSON array of columns to return
    requested_at: i64
).

// READ: Count rows
Decl hana_row_count(
    request_id: String,
    service_id: String,
    table_id: String,
    where_clause: String,
    requested_at: i64
).

// READ: Row result
Decl hana_row_result(
    request_id: String,
    columns: String,             // JSON array of column names
    rows_ref: String,            // TOON pointer to result data
    row_count: i32,
    total_count: i32,            // Total matching (before LIMIT)
    duration_ms: i64,
    status: String
).

// UPDATE: Update rows
Decl hana_row_update(
    request_id: String,
    service_id: String,
    table_id: String,
    set_values: String,          // JSON object of column:value
    where_clause: String,
    requested_at: i64
).

// UPDATE: Update by primary key
Decl hana_row_update_by_key(
    request_id: String,
    service_id: String,
    table_id: String,
    key_values: String,          // JSON object of key column:value
    set_values: String,          // JSON object of column:value
    requested_at: i64
).

// UPDATE: Batch update
Decl hana_row_batch_update(
    batch_id: String,
    service_id: String,
    table_id: String,
    key_columns: String,
    data_ref: String,            // TOON pointer to update data
    row_count: i32,
    requested_at: i64
).

// DELETE: Delete rows
Decl hana_row_delete(
    request_id: String,
    service_id: String,
    table_id: String,
    where_clause: String,
    requested_at: i64
).

// DELETE: Delete by primary key
Decl hana_row_delete_by_key(
    request_id: String,
    service_id: String,
    table_id: String,
    key_values: String,          // JSON object of key column:value
    requested_at: i64
).

// DELETE: Batch delete
Decl hana_row_batch_delete(
    batch_id: String,
    service_id: String,
    table_id: String,
    key_columns: String,
    keys_ref: String,            // TOON pointer to key data
    row_count: i32,
    requested_at: i64
).

// DML operation result
Decl hana_row_dml_result(
    request_id: String,
    operation: String,           // insert, update, delete, upsert
    status: String,
    rows_affected: i32,
    duration_ms: i64,
    error_message: String
).

// --- Vector Operations (HANA Cloud Vector Engine) - Full CRUD ---

// CREATE: Vector index definition
Decl hana_vector_index(
    index_id: String,
    schema: String,
    table: String,
    column: String,
    dimensions: i32,
    distance_metric: String      // cosine, euclidean, dot_product
).

// CREATE: Create a new vector index
Decl hana_vector_create_index(
    request_id: String,
    service_id: String,
    schema: String,
    table: String,
    column: String,
    dimensions: i32,
    distance_metric: String,
    requested_at: i64
).

// CREATE: Insert vector into table
Decl hana_vector_insert(
    request_id: String,
    service_id: String,
    schema: String,
    table: String,
    record_id: String,           // Primary key of record
    vector_data: String,         // TOON pointer or inline array
    metadata: String,            // JSON metadata
    requested_at: i64
).

// CREATE: Batch insert vectors
Decl hana_vector_batch_insert(
    batch_id: String,
    service_id: String,
    schema: String,
    table: String,
    vectors_ref: String,         // TOON pointer to batch data
    count: i32,
    requested_at: i64
).

// READ: Vector similarity search
Decl hana_vector_search(
    search_id: String,
    index_id: String,
    query_vector_ref: String,    // TOON pointer to vector
    k: i32,
    filter: String,              // Optional SQL WHERE clause
    executed_at: i64
).

// READ: Get vector by ID
Decl hana_vector_get(
    request_id: String,
    service_id: String,
    schema: String,
    table: String,
    record_id: String,
    requested_at: i64
).

// READ: Search result
Decl hana_vector_result(
    search_id: String,
    results: String,             // JSON array of {id, distance}
    duration_ms: i64
).

// UPDATE: Update vector data
Decl hana_vector_update(
    request_id: String,
    service_id: String,
    schema: String,
    table: String,
    record_id: String,
    new_vector_data: String,     // TOON pointer or inline array
    new_metadata: String,        // JSON metadata (optional)
    requested_at: i64
).

// DELETE: Delete vector by ID
Decl hana_vector_delete(
    request_id: String,
    service_id: String,
    schema: String,
    table: String,
    record_id: String,
    requested_at: i64
).

// DELETE: Drop vector index
Decl hana_vector_drop_index(
    request_id: String,
    service_id: String,
    index_id: String,
    requested_at: i64
).

// CRUD operation result
Decl hana_vector_operation_result(
    request_id: String,
    operation: String,           // create_index, insert, batch_insert, get, update, delete, drop_index
    status: String,              // success, error
    affected_rows: i32,
    duration_ms: i64,
    error_message: String
).

// --- PAL (Predictive Analysis Library) ---
Decl hana_pal_procedure(
    procedure_id: String,
    procedure_name: String,      // e.g., FORECAST, ANOMALYDETECTION
    input_tables: String,        // JSON array of table refs
    output_tables: String,       // JSON array of table refs
    parameters: String           // JSON object of PAL params
).

Decl hana_pal_execution(
    execution_id: String,
    procedure_id: String,
    status: String,              // running, completed, failed
    started_at: i64,
    completed_at: i64,
    error_message: String
).

// --- Graph Operations (HANA Graph) - Full CRUD ---

// CREATE: Graph workspace definition
Decl hana_graph_workspace(
    workspace_id: String,
    schema: String,
    workspace_name: String,
    vertex_tables: String,       // JSON array
    edge_tables: String          // JSON array
).

// CREATE: Create a new graph workspace
Decl hana_graph_create_workspace(
    request_id: String,
    service_id: String,
    schema: String,
    workspace_name: String,
    vertex_tables: String,       // JSON array of {table, key_column}
    edge_tables: String,         // JSON array of {table, source_column, target_column}
    requested_at: i64
).

// CREATE: Insert vertex
Decl hana_graph_insert_vertex(
    request_id: String,
    service_id: String,
    workspace_id: String,
    vertex_type: String,         // Vertex table name
    vertex_id: String,           // Primary key
    properties: String,          // JSON properties
    requested_at: i64
).

// CREATE: Insert edge
Decl hana_graph_insert_edge(
    request_id: String,
    service_id: String,
    workspace_id: String,
    edge_type: String,           // Edge table name
    source_vertex: String,       // Source vertex ID
    target_vertex: String,       // Target vertex ID
    properties: String,          // JSON properties
    requested_at: i64
).

// CREATE: Batch insert vertices/edges
Decl hana_graph_batch_insert(
    batch_id: String,
    service_id: String,
    workspace_id: String,
    element_type: String,        // vertex or edge
    data_ref: String,            // TOON pointer to batch data
    count: i32,
    requested_at: i64
).

// READ: Graph traversal
Decl hana_graph_traversal(
    traversal_id: String,
    workspace_id: String,
    start_vertex: String,
    direction: String,           // outgoing, incoming, any
    max_depth: i32,
    filter: String               // Optional filter expression
).

// READ: Get vertex by ID
Decl hana_graph_get_vertex(
    request_id: String,
    service_id: String,
    workspace_id: String,
    vertex_type: String,
    vertex_id: String,
    requested_at: i64
).

// READ: Get edges for vertex
Decl hana_graph_get_edges(
    request_id: String,
    service_id: String,
    workspace_id: String,
    vertex_id: String,
    direction: String,           // outgoing, incoming, any
    edge_type: String,           // Optional filter by edge type
    requested_at: i64
).

// READ: Shortest path
Decl hana_graph_shortest_path(
    request_id: String,
    service_id: String,
    workspace_id: String,
    source_vertex: String,
    target_vertex: String,
    weight_column: String,       // Optional edge weight column
    max_depth: i32,
    requested_at: i64
).

// READ: Pattern matching (MATCH clause)
Decl hana_graph_pattern_match(
    request_id: String,
    service_id: String,
    workspace_id: String,
    pattern: String,             // MATCH pattern like (a)-[e]->(b)
    where_clause: String,        // Optional WHERE filter
    return_columns: String,      // Columns to return
    limit: i32,
    requested_at: i64
).

// READ: Traversal result
Decl hana_graph_traversal_result(
    traversal_id: String,
    vertices: String,            // JSON array of vertices
    edges: String,               // JSON array of edges
    paths: String,               // JSON array of paths
    duration_ms: i64
).

// UPDATE: Update vertex properties
Decl hana_graph_update_vertex(
    request_id: String,
    service_id: String,
    workspace_id: String,
    vertex_type: String,
    vertex_id: String,
    new_properties: String,      // JSON properties to update
    requested_at: i64
).

// UPDATE: Update edge properties
Decl hana_graph_update_edge(
    request_id: String,
    service_id: String,
    workspace_id: String,
    edge_type: String,
    source_vertex: String,
    target_vertex: String,
    new_properties: String,      // JSON properties to update
    requested_at: i64
).

// DELETE: Delete vertex
Decl hana_graph_delete_vertex(
    request_id: String,
    service_id: String,
    workspace_id: String,
    vertex_type: String,
    vertex_id: String,
    cascade_edges: i32,          // 1 = delete connected edges, 0 = fail if edges exist
    requested_at: i64
).

// DELETE: Delete edge
Decl hana_graph_delete_edge(
    request_id: String,
    service_id: String,
    workspace_id: String,
    edge_type: String,
    source_vertex: String,
    target_vertex: String,
    requested_at: i64
).

// DELETE: Drop graph workspace
Decl hana_graph_drop_workspace(
    request_id: String,
    service_id: String,
    workspace_id: String,
    requested_at: i64
).

// CRUD operation result
Decl hana_graph_operation_result(
    request_id: String,
    operation: String,           // create_workspace, insert_vertex, insert_edge, etc.
    status: String,              // success, error
    affected_count: i32,
    duration_ms: i64,
    error_message: String
).

// ============================================================================
// Rules - Connection Health & Routing
// ============================================================================

// A HANA connection is healthy if recently used and status is connected
hana_healthy(ServiceId, ConnectionId) :-
    hana_connection(ConnectionId, ServiceId, "connected", _, LastUsed),
    now(Now),
    Now - LastUsed < 300000.  // 5 minutes in ms

// Resolve HANA config for a service
resolve_hana(ServiceId, Host, Port, Schema) :-
    hana_config(ServiceId, Host, Port, Schema, _).

// ============================================================================
// Rules - Schema Operations
// ============================================================================

// Schema exists
schema_exists(SchemaName) :-
    hana_schema(_, SchemaName, _, _, _).

// User has privilege on schema
user_has_schema_privilege(User, SchemaName, PrivilegeType) :-
    hana_schema_privilege(_, SchemaName, User, PrivilegeType, _, _).

// User can create objects in schema
user_can_create_in_schema(User, SchemaName) :-
    user_has_schema_privilege(User, SchemaName, "CREATE ANY").

// Schema operation succeeded
schema_operation_succeeded(RequestId) :-
    hana_schema_operation_result(RequestId, _, "success", _, _, _).

// ============================================================================
// Rules - View Operations
// ============================================================================

// View exists
view_exists(Schema, ViewName) :-
    hana_view(_, Schema, ViewName, _, _, _, _, _).

// View is valid (no broken dependencies)
view_is_valid(ViewId) :-
    hana_view(ViewId, _, _, _, _, 1, _, _).

// View is materialized
view_is_materialized(ViewId) :-
    hana_view(ViewId, _, _, "materialized", _, _, _, _).

// View operation succeeded
view_operation_succeeded(RequestId) :-
    hana_view_operation_result(RequestId, _, "success", _, _, _).

// Orphan view operation
orphan_view_operation(RequestId) :-
    (hana_view_create(RequestId, _, _, _, _, _, _, _) ;
     hana_view_drop(RequestId, _, _, _, _)),
    not(hana_view_operation_result(RequestId, _, _, _, _, _)).

// ============================================================================
// Rules - Sequence Operations
// ============================================================================

// Sequence exists
sequence_exists(Schema, SequenceName) :-
    hana_sequence(_, Schema, SequenceName, _, _, _, _, _, _, _, _).

// Sequence is cycling
sequence_cycles(SequenceId) :-
    hana_sequence(SequenceId, _, _, _, _, _, _, 1, _, _, _).

// Sequence operation succeeded
sequence_operation_succeeded(RequestId) :-
    hana_sequence_operation_result(RequestId, _, "success", _, _, _).

// Get next value result
sequence_nextval_result(RequestId, Value) :-
    hana_sequence_operation_result(RequestId, "nextval", "success", Value, _, _).

// ============================================================================
// Rules - Synonym Operations
// ============================================================================

// Synonym exists
synonym_exists(Schema, SynonymName) :-
    hana_synonym(_, Schema, SynonymName, _, _, _, _, _).

// Synonym is public
synonym_is_public(SynonymId) :-
    hana_synonym(SynonymId, _, _, _, _, _, 1, _).

// Synonym target exists
synonym_target_valid(SynonymId) :-
    hana_synonym(SynonymId, _, _, TargetSchema, TargetObject, TargetType, _, _),
    (TargetType = "TABLE", table_exists(TargetSchema, TargetObject)) ;
    (TargetType = "VIEW", view_exists(TargetSchema, TargetObject)) ;
    (TargetType = "PROCEDURE", procedure_exists(TargetSchema, TargetObject)) ;
    (TargetType = "FUNCTION", function_exists(TargetSchema, TargetObject)) ;
    (TargetType = "SEQUENCE", sequence_exists(TargetSchema, TargetObject)).

// Synonym operation succeeded
synonym_operation_succeeded(RequestId) :-
    hana_synonym_operation_result(RequestId, _, "success", _, _, _).

// ============================================================================
// Rules - Procedure Operations
// ============================================================================

// Procedure exists
procedure_exists(Schema, ProcedureName) :-
    hana_procedure(_, Schema, ProcedureName, _, _, _, _, _, _, _).

// Procedure is read-only
procedure_is_read_only(ProcedureId) :-
    hana_procedure(ProcedureId, _, _, _, _, 1, _, _, _, _).

// Procedure uses SQLScript
procedure_uses_sqlscript(ProcedureId) :-
    hana_procedure(ProcedureId, _, _, "SQLSCRIPT", _, _, _, _, _, _).

// Procedure operation succeeded
procedure_operation_succeeded(RequestId) :-
    hana_procedure_operation_result(RequestId, _, "success", _, _, _).

// Procedure call succeeded
procedure_call_succeeded(RequestId) :-
    hana_procedure_result(RequestId, _, _, _, "success").

// Procedure has OUT parameters
procedure_has_out_params(ProcedureId) :-
    hana_procedure_param(_, ProcedureId, _, _, Mode, _, _),
    (Mode = "OUT" ; Mode = "INOUT").

// ============================================================================
// Rules - Function Operations
// ============================================================================

// Function exists
function_exists(Schema, FunctionName) :-
    hana_function(_, Schema, FunctionName, _, _, _, _, _, _, _, _).

// Function is deterministic
function_is_deterministic(FunctionId) :-
    hana_function(FunctionId, _, _, _, _, 1, _, _, _, _, _).

// Function operation succeeded
function_operation_succeeded(RequestId) :-
    hana_function_operation_result(RequestId, _, "success", _, _, _).

// Function call succeeded
function_call_succeeded(RequestId) :-
    hana_function_result(RequestId, _, _, "success").

// ============================================================================
// Rules - Schema Object Counts
// ============================================================================

// Count tables in schema
schema_table_count(Schema, Count) :-
    aggregate(hana_table(_, Schema, _, _, _, _, _), count, Count).

// Count views in schema
schema_view_count(Schema, Count) :-
    aggregate(hana_view(_, Schema, _, _, _, _, _, _), count, Count).

// Count procedures in schema
schema_procedure_count(Schema, Count) :-
    aggregate(hana_procedure(_, Schema, _, _, _, _, _, _, _, _), count, Count).

// Count functions in schema
schema_function_count(Schema, Count) :-
    aggregate(hana_function(_, Schema, _, _, _, _, _, _, _, _, _), count, Count).

// Count sequences in schema
schema_sequence_count(Schema, Count) :-
    aggregate(hana_sequence(_, Schema, _, _, _, _, _, _, _, _, _), count, Count).

// Total objects in schema
schema_total_objects(Schema, Total) :-
    schema_table_count(Schema, Tables),
    schema_view_count(Schema, Views),
    schema_procedure_count(Schema, Procs),
    schema_function_count(Schema, Funcs),
    schema_sequence_count(Schema, Seqs),
    Total = Tables + Views + Procs + Funcs + Seqs.

// ============================================================================
// Rules - Table DDL Operations
// ============================================================================

// Table exists
table_exists(Schema, TableName) :-
    hana_table(_, Schema, TableName, _, _, _, _).

// Table has primary key
table_has_pk(TableId) :-
    hana_column(_, TableId, _, _, _, _, _, _, _, 1, _).

// Table is partitioned
table_is_partitioned(TableId) :-
    hana_table(TableId, _, _, _, _, PartSpec, _),
    PartSpec != "".

// Column exists in table
column_exists(TableId, ColumnName) :-
    hana_column(_, TableId, ColumnName, _, _, _, _, _, _, _, _).

// Table DDL operation succeeded
table_ddl_succeeded(RequestId) :-
    hana_table_ddl_result(RequestId, _, "success", _, _, _).

// Orphan DDL operation (no result)
orphan_table_ddl(RequestId) :-
    (hana_table_create(RequestId, _, _, _, _, _, _, _, _) ;
     hana_table_drop(RequestId, _, _, _, _) ;
     hana_table_add_column(RequestId, _, _, _, _, _, _, _, _)),
    not(hana_table_ddl_result(RequestId, _, _, _, _, _)).

// Get all columns for table
table_columns(TableId, ColumnList) :-
    aggregate(hana_column(_, TableId, Name, _, _, _, _, _, _, _, _), collect, ColumnList).

// Get primary key columns
table_pk_columns(TableId, PKColumns) :-
    aggregate(hana_column(_, TableId, Name, _, _, _, _, _, _, 1, _), collect, PKColumns).

// Table has foreign key to another table
table_references(TableId, RefTableId) :-
    hana_constraint(_, TableId, _, "foreign_key", _, RefTable, _, _),
    hana_table(RefTableId, _, RefTable, _, _, _, _).

// ============================================================================
// Rules - Row DML Operations
// ============================================================================

// Table is writable (has PK and connection healthy)
table_writable(ServiceId, TableId) :-
    hana_table(TableId, Schema, _, _, _, _, _),
    hana_healthy(ServiceId, _),
    resolve_hana(ServiceId, _, _, Schema),
    table_has_pk(TableId).

// Row DML operation succeeded
row_dml_succeeded(RequestId) :-
    hana_row_dml_result(RequestId, _, "success", _, _, _).

// Get affected rows from DML
dml_affected_rows(RequestId, Count) :-
    hana_row_dml_result(RequestId, _, "success", Count, _, _).

// Orphan DML operation (no result)
orphan_row_dml(RequestId) :-
    (hana_row_insert(RequestId, _, _, _, _, _) ;
     hana_row_update(RequestId, _, _, _, _, _) ;
     hana_row_delete(RequestId, _, _, _, _)),
    not(hana_row_dml_result(RequestId, _, _, _, _, _)).

// Batch operation in progress
batch_in_progress(BatchId) :-
    (hana_row_batch_insert(BatchId, _, _, _, _, _, _) ;
     hana_row_batch_update(BatchId, _, _, _, _, _, _) ;
     hana_row_batch_delete(BatchId, _, _, _, _, _, _)),
    not(hana_row_dml_result(BatchId, _, _, _, _, _)).

// Select has result
select_has_result(RequestId) :-
    hana_row_select(RequestId, _, _, _, _, _, _, _, _),
    hana_row_result(RequestId, _, _, _, _, _, _).

// Row exists (after insert, before delete)
row_exists_estimate(TableId, KeyValues) :-
    hana_row_insert(_, _, TableId, _, KeyValues, _),
    row_dml_succeeded(_),
    not(hana_row_delete_by_key(_, _, TableId, KeyValues, _)).

// ============================================================================
// Rules - Aggregate DML Statistics
// ============================================================================

// Total rows inserted into table
total_rows_inserted(ServiceId, TableId, Total) :-
    aggregate(hana_row_dml_result(ReqId, "insert", "success", Count, _, _), sum, Total),
    hana_row_insert(ReqId, ServiceId, TableId, _, _, _).

// Total rows updated in table
total_rows_updated(ServiceId, TableId, Total) :-
    aggregate(hana_row_dml_result(ReqId, "update", "success", Count, _, _), sum, Total),
    hana_row_update(ReqId, ServiceId, TableId, _, _, _).

// Total rows deleted from table
total_rows_deleted(ServiceId, TableId, Total) :-
    aggregate(hana_row_dml_result(ReqId, "delete", "success", Count, _, _), sum, Total),
    hana_row_delete(ReqId, ServiceId, TableId, _, _).

// Estimated row count (inserts - deletes)
estimated_row_count(ServiceId, TableId, Estimate) :-
    total_rows_inserted(ServiceId, TableId, Inserted),
    total_rows_deleted(ServiceId, TableId, Deleted),
    Estimate = Inserted - Deleted.

// ============================================================================
// Rules - Vector Operations
// ============================================================================

// Vector search is available if index exists and connection healthy
vector_search_available(ServiceId, IndexId) :-
    hana_vector_index(IndexId, Schema, _, _, _, _),
    hana_connection(ConnId, ServiceId, "connected", _, _),
    resolve_hana(ServiceId, _, _, Schema).

// Vector CRUD available if connection healthy
vector_crud_available(ServiceId, Schema, Table) :-
    hana_healthy(ServiceId, _),
    resolve_hana(ServiceId, _, _, Schema).

// Vector operation succeeded
vector_operation_succeeded(RequestId) :-
    hana_vector_operation_result(RequestId, _, "success", _, _, _).

// Vector operation has result
vector_operation_has_result(RequestId) :-
    (hana_vector_insert(RequestId, _, _, _, _, _, _, _) ;
     hana_vector_update(RequestId, _, _, _, _, _, _, _) ;
     hana_vector_delete(RequestId, _, _, _, _, _) ;
     hana_vector_get(RequestId, _, _, _, _, _)),
    hana_vector_operation_result(RequestId, _, _, _, _, _).

// Orphan vector operation (no result)
orphan_vector_operation(RequestId) :-
    (hana_vector_insert(RequestId, _, _, _, _, _, _, _) ;
     hana_vector_update(RequestId, _, _, _, _, _, _, _) ;
     hana_vector_delete(RequestId, _, _, _, _, _)),
    not(hana_vector_operation_result(RequestId, _, _, _, _, _)).

// ============================================================================
// Rules - PAL Operations
// ============================================================================

// PAL is available if connection healthy
pal_available(ServiceId, ProcedureName) :-
    hana_pal_procedure(ProcId, ProcedureName, _, _, _),
    hana_healthy(ServiceId, _).

// ============================================================================
// Rules - Graph Operations
// ============================================================================

// Graph workspace is available
graph_workspace_available(ServiceId, WorkspaceId) :-
    hana_graph_workspace(WorkspaceId, Schema, _, _, _),
    hana_healthy(ServiceId, _),
    resolve_hana(ServiceId, _, _, Schema).

// Graph CRUD available if workspace exists and connection healthy
graph_crud_available(ServiceId, WorkspaceId) :-
    hana_graph_workspace(WorkspaceId, _, _, _, _),
    hana_healthy(ServiceId, _).

// Graph traversal available
graph_traversal_available(ServiceId, WorkspaceId) :-
    graph_workspace_available(ServiceId, WorkspaceId).

// Graph operation succeeded
graph_operation_succeeded(RequestId) :-
    hana_graph_operation_result(RequestId, _, "success", _, _, _).

// Graph operation has result
graph_operation_has_result(RequestId) :-
    (hana_graph_insert_vertex(RequestId, _, _, _, _, _, _) ;
     hana_graph_insert_edge(RequestId, _, _, _, _, _, _, _) ;
     hana_graph_update_vertex(RequestId, _, _, _, _, _, _) ;
     hana_graph_update_edge(RequestId, _, _, _, _, _, _, _) ;
     hana_graph_delete_vertex(RequestId, _, _, _, _, _, _) ;
     hana_graph_delete_edge(RequestId, _, _, _, _, _, _)),
    hana_graph_operation_result(RequestId, _, _, _, _, _).

// Orphan graph operation (no result)
orphan_graph_operation(RequestId) :-
    (hana_graph_insert_vertex(RequestId, _, _, _, _, _, _) ;
     hana_graph_insert_edge(RequestId, _, _, _, _, _, _, _) ;
     hana_graph_update_vertex(RequestId, _, _, _, _, _, _) ;
     hana_graph_update_edge(RequestId, _, _, _, _, _, _, _) ;
     hana_graph_delete_vertex(RequestId, _, _, _, _, _, _) ;
     hana_graph_delete_edge(RequestId, _, _, _, _, _, _)),
    not(hana_graph_operation_result(RequestId, _, _, _, _, _)).

// Vertex exists in workspace
vertex_exists(WorkspaceId, VertexType, VertexId) :-
    hana_graph_insert_vertex(_, _, WorkspaceId, VertexType, VertexId, _, _),
    graph_operation_succeeded(_),
    not(hana_graph_delete_vertex(_, _, WorkspaceId, VertexType, VertexId, _, _)).

// Edge exists in workspace
edge_exists(WorkspaceId, EdgeType, Source, Target) :-
    hana_graph_insert_edge(_, _, WorkspaceId, EdgeType, Source, Target, _, _),
    graph_operation_succeeded(_),
    not(hana_graph_delete_edge(_, _, WorkspaceId, EdgeType, Source, Target, _)).

// ============================================================================
// Aggregate Statistics
// ============================================================================

// Count vectors in table
vector_count(ServiceId, Schema, Table, Count) :-
    aggregate(hana_vector_insert(_, ServiceId, Schema, Table, _, _, _, _), count, Inserted),
    aggregate(hana_vector_delete(_, ServiceId, Schema, Table, _, _), count, Deleted),
    Count = Inserted - Deleted.

// Count vertices in workspace
vertex_count(WorkspaceId, VertexType, Count) :-
    aggregate(hana_graph_insert_vertex(_, _, WorkspaceId, VertexType, _, _, _), count, Inserted),
    aggregate(hana_graph_delete_vertex(_, _, WorkspaceId, VertexType, _, _, _), count, Deleted),
    Count = Inserted - Deleted.

// Count edges in workspace
edge_count(WorkspaceId, EdgeType, Count) :-
    aggregate(hana_graph_insert_edge(_, _, WorkspaceId, EdgeType, _, _, _, _), count, Inserted),
    aggregate(hana_graph_delete_edge(_, _, WorkspaceId, EdgeType, _, _, _), count, Deleted),
    Count = Inserted - Deleted.
