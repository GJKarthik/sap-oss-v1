# SAC Widget Component Specification
# Mangle Datalog for SAP Analytics Cloud Angular Components
#
# Derives Angular component structure from widget type definitions.
# Integrates with sap-sac-webcomponents-ts/specs/sacwidgetclient/

# =============================================================================
# Widget Type Facts (from TypeScript enums)
# =============================================================================

# Widget categories
widget_category("Chart", "visualization").
widget_category("Table", "visualization").
widget_category("Text", "display").
widget_category("Image", "display").
widget_category("Shape", "display").
widget_category("Button", "input").
widget_category("Dropdown", "input").
widget_category("Checkbox", "input").
widget_category("RadioButton", "input").
widget_category("InputField", "input").
widget_category("DatePicker", "input").
widget_category("Slider", "input").
widget_category("FilterLine", "filter").
widget_category("GeoMap", "advanced").
widget_category("RVisualization", "advanced").
widget_category("CustomWidget", "custom").
widget_category("Container", "layout").

# Chart types
chart_type("bar", "categorical").
chart_type("column", "categorical").
chart_type("line", "trend").
chart_type("area", "trend").
chart_type("pie", "part_to_whole").
chart_type("donut", "part_to_whole").
chart_type("bubble", "correlation").
chart_type("scatter", "correlation").
chart_type("waterfall", "variance").
chart_type("treemap", "hierarchical").
chart_type("heatmap", "matrix").
chart_type("bullet", "comparison").
chart_type("combo", "mixed").
chart_type("stacked_bar", "categorical").
chart_type("stacked_column", "categorical").
chart_type("variance", "variance").

# Feed types for charts
chart_feed("categoryAxis", "dimension").
chart_feed("color", "dimension").
chart_feed("valueAxis", "measure").
chart_feed("bubbleWidth", "measure").
chart_feed("bubbleHeight", "measure").
chart_feed("trellis", "dimension").

# =============================================================================
# Angular Component Derivation Rules
# =============================================================================

# Derive Angular selector from widget type
angular_selector(WidgetType, Selector) :-
    widget_category(WidgetType, _),
    Selector = fn:concat("sac-", fn:lowercase(WidgetType)).

# Derive Angular module from category
angular_module(Category, ModuleName) :-
    widget_category(_, Category),
    ModuleName = fn:concat("Sac", fn:capitalize(Category), "Module").

# Derive component class name
component_class(WidgetType, ClassName) :-
    widget_category(WidgetType, _),
    ClassName = fn:concat("Sac", WidgetType, "Component").

# Derive service class name
service_class(WidgetType, ServiceName) :-
    widget_category(WidgetType, _),
    ServiceName = fn:concat("Sac", WidgetType, "Service").

# =============================================================================
# Input/Output Properties Derivation
# =============================================================================

# Standard widget inputs
widget_input("visible", "boolean", "true").
widget_input("enabled", "boolean", "true").
widget_input("cssClass", "string", "''").
widget_input("width", "string", "'auto'").
widget_input("height", "string", "'auto'").

# Chart-specific inputs
chart_input("chartType", "ChartType", "ChartType.Bar").
chart_input("dataSource", "DataSource", "null").
chart_input("showLegend", "boolean", "true").
chart_input("legendPosition", "ChartLegendPosition", "ChartLegendPosition.Bottom").

# Table-specific inputs
table_input("dataSource", "DataSource", "null").
table_input("showHeaders", "boolean", "true").
table_input("enableSorting", "boolean", "true").
table_input("enableFiltering", "boolean", "true").

# Input control inputs
input_control_input("value", "any", "null").
input_control_input("label", "string", "''").
input_control_input("placeholder", "string", "''").
input_control_input("required", "boolean", "false").
input_control_input("disabled", "boolean", "false").

# =============================================================================
# Event Outputs Derivation
# =============================================================================

# Standard widget events
widget_output("onClick", "SACEvent").
widget_output("onResize", "SACEvent").
widget_output("onSelectionChange", "SelectionContext").

# Chart events
chart_output("onDataPointClick", "DataPoint").
chart_output("onLegendClick", "string").
chart_output("onZoom", "ZoomEvent").

# Table events
table_output("onCellClick", "CellInfo").
table_output("onRowSelect", "RowInfo").
table_output("onSort", "SortSpec").
table_output("onFilter", "FilterValue").

# Input control events
input_control_output("onChange", "any").
input_control_output("onFocus", "FocusEvent").
input_control_output("onBlur", "FocusEvent").

# =============================================================================
# DataSource Integration
# =============================================================================

# Datasource properties
datasource_property("modelId", "string").
datasource_property("dimensions", "DimensionInfo[]").
datasource_property("measures", "MeasureInfo[]").
datasource_property("filters", "FilterValue[]").
datasource_property("variables", "VariableValue[]").

# Datasource methods
datasource_method("refresh", "void", []).
datasource_method("setFilter", "void", ["dimension: string", "value: FilterValue"]).
datasource_method("removeFilter", "void", ["dimension: string"]).
datasource_method("setVariable", "void", ["variable: string", "value: VariableValue"]).
datasource_method("getData", "ResultSet", []).

# =============================================================================
# Module Organization
# =============================================================================

# Core module components
module_component("core", "Application").
module_component("core", "ScriptObject").
module_component("core", "Layout").

# Visualization module components
module_component("visualization", "Chart").
module_component("visualization", "Table").
module_component("visualization", "GeoMap").
module_component("visualization", "KPI").

# Input module components
module_component("input", "Button").
module_component("input", "Dropdown").
module_component("input", "InputField").
module_component("input", "DatePicker").
module_component("input", "Slider").
module_component("input", "Checkbox").
module_component("input", "RadioButton").

# Layout module components
module_component("layout", "Panel").
module_component("layout", "Popup").
module_component("layout", "TabStrip").
module_component("layout", "PageBook").
module_component("layout", "FlowPanel").

# Planning module components
module_component("planning", "PlanningModel").
module_component("planning", "DataAction").
module_component("planning", "Allocation").

# =============================================================================
# API Endpoint Mapping
# =============================================================================

# SAC API endpoints for widgets
api_endpoint("widget", "GET", "/api/v1/widgets").
api_endpoint("widget", "GET", "/api/v1/widgets/{id}").
api_endpoint("widget", "POST", "/api/v1/widgets").
api_endpoint("widget", "PUT", "/api/v1/widgets/{id}").
api_endpoint("widget", "DELETE", "/api/v1/widgets/{id}").

# DataSource API endpoints
api_endpoint("datasource", "GET", "/api/v1/datasources").
api_endpoint("datasource", "GET", "/api/v1/datasources/{id}").
api_endpoint("datasource", "POST", "/api/v1/datasources/{id}/data").
api_endpoint("datasource", "POST", "/api/v1/datasources/{id}/filter").
api_endpoint("datasource", "POST", "/api/v1/datasources/{id}/variables").

# Planning API endpoints
api_endpoint("planning", "GET", "/api/v1/planning/models").
api_endpoint("planning", "POST", "/api/v1/planning/dataactions/{id}/execute").
api_endpoint("planning", "POST", "/api/v1/planning/publish").
api_endpoint("planning", "POST", "/api/v1/planning/lock").