# SAC DataSource Specification
# Mangle Datalog for SAP Analytics Cloud DataSource Integration
#
# Derives datasource operations, filtering, and variable handling.
# Source: sap-sac-webcomponents-ts/specs/sacwidgetclient/datasource/

# =============================================================================
# Dimension Types (from dimensioninfo_client.odps.yaml)
# =============================================================================

# Dimension type facts
dimension_type("Account", "account", true).
dimension_type("Category", "generic", false).
dimension_type("Date", "time", true).
dimension_type("Entity", "generic", false).
dimension_type("Flow", "generic", false).
dimension_type("Generic", "generic", false).
dimension_type("Measure", "measure", true).
dimension_type("Organization", "generic", false).
dimension_type("Time", "time", true).
dimension_type("Version", "version", true).

# Dimension data types
dimension_data_type("String", "alphanumeric").
dimension_data_type("Integer", "numeric").
dimension_data_type("Date", "temporal").
dimension_data_type("Time", "temporal").
dimension_data_type("DateTime", "temporal").

# =============================================================================
# Measure Types (from measureinfo_client.odps.yaml)
# =============================================================================

# Measure data types
measure_data_type("Amount", "currency").
measure_data_type("Quantity", "unit").
measure_data_type("Price", "ratio").
measure_data_type("Percentage", "ratio").
measure_data_type("Integer", "count").
measure_data_type("Number", "numeric").

# Aggregation types
aggregation_type("SUM").
aggregation_type("AVG").
aggregation_type("MIN").
aggregation_type("MAX").
aggregation_type("COUNT").
aggregation_type("COUNTD").
aggregation_type("FIRST").
aggregation_type("LAST").
aggregation_type("NOP").

# =============================================================================
# Filter Value Types (from filtervalue_client.odps.yaml)
# =============================================================================

# Filter value type facts
filter_value_type("SingleValue", "exact_match").
filter_value_type("MultipleValue", "in_list").
filter_value_type("RangeValue", "between").
filter_value_type("AllValue", "no_filter").
filter_value_type("ExcludeValue", "not_in").

# Filter operations
filter_operation("equal", "SingleValue", "=").
filter_operation("not_equal", "SingleValue", "!=").
filter_operation("in", "MultipleValue", "IN").
filter_operation("not_in", "ExcludeValue", "NOT IN").
filter_operation("between", "RangeValue", "BETWEEN").
filter_operation("greater_than", "RangeValue", ">").
filter_operation("less_than", "RangeValue", "<").
filter_operation("contains", "SingleValue", "LIKE").
filter_operation("starts_with", "SingleValue", "LIKE").
filter_operation("ends_with", "SingleValue", "LIKE").

# =============================================================================
# Variable Types (from variableinfo_client.odps.yaml)
# =============================================================================

# Variable types
variable_type("SingleValue", "single").
variable_type("MultipleValue", "multi").
variable_type("RangeValue", "range").
variable_type("IntervalValue", "interval").

# Variable input types
variable_input_type("Optional", false).
variable_input_type("Mandatory", true).
variable_input_type("MandatoryNotInitial", true).

# =============================================================================
# Member Types (from memberinfo_client.odps.yaml)
# =============================================================================

# Member types
member_type("Base", "leaf").
member_type("Parent", "node").
member_type("Text", "label").
member_type("Formula", "calculated").

# Member status
member_status("Active", true).
member_status("Inactive", false).
member_status("Hidden", false).
member_status("ReadOnly", true).

# Member display modes
member_display_mode("Key", "id_only").
member_display_mode("Text", "text_only").
member_display_mode("KeyAndText", "id_text").
member_display_mode("TextAndKey", "text_id").

# =============================================================================
# DataSource Service Methods
# =============================================================================

# Query methods
service_method("DataSource", "getData", "ResultSet", "async").
service_method("DataSource", "getMembers", "MemberInfo[]", "async").
service_method("DataSource", "getDimensions", "DimensionInfo[]", "sync").
service_method("DataSource", "getMeasures", "MeasureInfo[]", "sync").
service_method("DataSource", "getVariables", "VariableInfo[]", "sync").

# Filter methods
service_method("DataSource", "setDimensionFilter", "void", "async").
service_method("DataSource", "removeDimensionFilter", "void", "async").
service_method("DataSource", "clearAllFilters", "void", "async").
service_method("DataSource", "getActiveFilters", "FilterValue[]", "sync").

# Variable methods
service_method("DataSource", "setVariableValue", "void", "async").
service_method("DataSource", "getVariableValue", "VariableValue", "sync").
service_method("DataSource", "resetVariables", "void", "async").

# State methods
service_method("DataSource", "refresh", "void", "async").
service_method("DataSource", "pause", "void", "sync").
service_method("DataSource", "resume", "void", "sync").
service_method("DataSource", "getState", "DataSourceState", "sync").

# =============================================================================
# ResultSet Structure (from resultset_client.odps.yaml)
# =============================================================================

# ResultSet properties
resultset_property("data", "DataCell[][]").
resultset_property("dimensions", "string[]").
resultset_property("measures", "string[]").
resultset_property("rowCount", "number").
resultset_property("columnCount", "number").
resultset_property("metadata", "ResultSetMetadata").

# DataCell properties
datacell_property("value", "any").
datacell_property("formatted", "string").
datacell_property("unit", "string").
datacell_property("currency", "string").
datacell_property("status", "CellStatus").

# =============================================================================
# Angular DataSource Service
# =============================================================================

# Injectable service definition
angular_service("SacDataSourceService", "root").
angular_service("SacFilterService", "root").
angular_service("SacVariableService", "root").

# Service dependencies
service_dependency("SacDataSourceService", "HttpClient").
service_dependency("SacDataSourceService", "SacConfigService").
service_dependency("SacFilterService", "SacDataSourceService").
service_dependency("SacVariableService", "SacDataSourceService").

# Observable streams
service_observable("SacDataSourceService", "data$", "ResultSet").
service_observable("SacDataSourceService", "loading$", "boolean").
service_observable("SacDataSourceService", "error$", "Error | null").
service_observable("SacFilterService", "filters$", "FilterValue[]").
service_observable("SacVariableService", "variables$", "VariableValue[]").

# =============================================================================
# Linked Analysis (from linkedanalysis_client.odps.yaml)
# =============================================================================

# Linked analysis types
linked_analysis_type("drill", "navigation").
linked_analysis_type("filter", "filtering").
linked_analysis_type("selection", "highlighting").

# Linked analysis scope
linked_analysis_scope("Same Model", "same_model").
linked_analysis_scope("All Models", "all_models").
linked_analysis_scope("Selected Widgets", "selected").

# =============================================================================
# Selection Context (from selectioncontext_client.odps.yaml)
# =============================================================================

# Selection context properties
selection_context_property("dimension", "string").
selection_context_property("members", "MemberInfo[]").
selection_context_property("isAllSelected", "boolean").
selection_context_property("source", "WidgetType").