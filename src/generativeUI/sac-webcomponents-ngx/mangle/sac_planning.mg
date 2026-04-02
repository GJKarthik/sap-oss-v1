# SAC Planning Module Specification
# Mangle Datalog for SAP Analytics Cloud Planning operations
#
# Derives planning services, data actions, and allocation operations.
# Source: sap-sac-webcomponents-ts/specs/sacwidgetclient/planning/

# =============================================================================
# Planning Categories (from TypeScript enums)
# =============================================================================

# Planning category types
planning_category("Actual", "historical_data").
planning_category("Plan", "planned_data").
planning_category("Forecast", "projected_data").
planning_category("Budget", "allocated_funds").

# Planning copy options
planning_copy_option("Overwrite", "replace").
planning_copy_option("Add", "sum").
planning_copy_option("Subtract", "difference").
planning_copy_option("Multiply", "product").
planning_copy_option("Divide", "quotient").

# =============================================================================
# Data Locking States
# =============================================================================

# Lock states
data_lock_state("Unlocked", false).
data_lock_state("Locked", true).
data_lock_state("PartiallyLocked", true).

# Lock scopes
data_lock_scope("All").
data_lock_scope("Selected").
data_lock_scope("FilteredData").

# =============================================================================
# Version Types
# =============================================================================

# Version types
version_type("Public", "shared").
version_type("Private", "personal").
version_type("Actual", "historical").

# Version operations
version_operation("create", "Private").
version_operation("publish", "Private").
version_operation("delete", "Private").
version_operation("merge", "Private").
version_operation("compare", "Public").

# =============================================================================
# Data Action Types
# =============================================================================

# Data action parameter types
data_action_param_type("Member", "dimension_member").
data_action_param_type("Number", "numeric_value").
data_action_param_type("String", "text_value").
data_action_param_type("Date", "date_value").
data_action_param_type("DateTime", "datetime_value").

# Data action execution status
data_action_status("Success", true, false).
data_action_status("Failed", false, true).
data_action_status("PartialSuccess", true, true).
data_action_status("Cancelled", false, false).
data_action_status("Running", false, false).
data_action_status("Pending", false, false).

# =============================================================================
# Planning Model Service Methods
# =============================================================================

# Version methods
service_method("PlanningModel", "createPrivateVersion", "VersionInfo", "async").
service_method("PlanningModel", "publishPrivateVersion", "void", "async").
service_method("PlanningModel", "deletePrivateVersion", "void", "async").
service_method("PlanningModel", "getVersions", "VersionInfo[]", "async").
service_method("PlanningModel", "setWorkingVersion", "void", "sync").

# Lock methods
service_method("PlanningModel", "lockData", "LockInfo", "async").
service_method("PlanningModel", "unlockData", "void", "async").
service_method("PlanningModel", "getLockStatus", "LockInfo", "sync").

# Data methods
service_method("PlanningModel", "saveData", "void", "async").
service_method("PlanningModel", "revertData", "void", "async").
service_method("PlanningModel", "copyData", "void", "async").
service_method("PlanningModel", "clearData", "void", "async").

# =============================================================================
# Data Action Service Methods
# =============================================================================

# Execution methods
service_method("DataAction", "execute", "DataActionResult", "async").
service_method("DataAction", "executeBackground", "string", "async").
service_method("DataAction", "getStatus", "DataActionStatus", "async").
service_method("DataAction", "cancel", "void", "async").

# Parameter methods
service_method("DataAction", "getParameters", "DataActionParameter[]", "sync").
service_method("DataAction", "setParameter", "void", "sync").
service_method("DataAction", "validateParameters", "ValidationResult", "sync").

# =============================================================================
# Allocation Service Methods
# =============================================================================

# Allocation types
allocation_type("Equal", "distribute_equally").
allocation_type("Proportional", "distribute_by_ratio").
allocation_type("WeightBased", "distribute_by_weight").
allocation_type("Reference", "distribute_by_reference").

# Allocation methods
service_method("Allocation", "execute", "AllocationResult", "async").
service_method("Allocation", "preview", "AllocationResult", "async").
service_method("Allocation", "validate", "ValidationResult", "sync").

# =============================================================================
# Angular Service Derivation
# =============================================================================

# Planning services (from angular_service facts)
angular_service("SacPlanningModelService", "root").
angular_service("SacDataActionService", "root").
angular_service("SacAllocationService", "root").

# Service dependencies
service_dependency("SacPlanningModelService", "HttpClient").
service_dependency("SacPlanningModelService", "SacConfigService").
service_dependency("SacDataActionService", "HttpClient").
service_dependency("SacDataActionService", "SacConfigService").
service_dependency("SacAllocationService", "HttpClient").
service_dependency("SacAllocationService", "SacPlanningModelService").

# Observable streams for planning
service_observable("SacPlanningModelService", "versions$", "VersionInfo[]").
service_observable("SacPlanningModelService", "lockStatus$", "LockInfo").
service_observable("SacPlanningModelService", "dirty$", "boolean").
service_observable("SacDataActionService", "executionStatus$", "DataActionStatus").
service_observable("SacDataActionService", "lastResult$", "DataActionResult").

# =============================================================================
# API Endpoint Mapping
# =============================================================================

# Planning Model endpoints
api_endpoint("planning", "GET", "/api/v1/planning/models/{modelId}").
api_endpoint("planning", "GET", "/api/v1/planning/models/{modelId}/versions").
api_endpoint("planning", "POST", "/api/v1/planning/models/{modelId}/versions").
api_endpoint("planning", "DELETE", "/api/v1/planning/models/{modelId}/versions/{versionId}").
api_endpoint("planning", "POST", "/api/v1/planning/models/{modelId}/publish").

# Data Action endpoints
api_endpoint("dataaction", "GET", "/api/v1/dataactions").
api_endpoint("dataaction", "GET", "/api/v1/dataactions/{id}").
api_endpoint("dataaction", "POST", "/api/v1/dataactions/{id}/execute").
api_endpoint("dataaction", "GET", "/api/v1/dataactions/{id}/status/{executionId}").
api_endpoint("dataaction", "POST", "/api/v1/dataactions/{id}/cancel/{executionId}").

# Lock endpoints
api_endpoint("lock", "POST", "/api/v1/planning/models/{modelId}/lock").
api_endpoint("lock", "DELETE", "/api/v1/planning/models/{modelId}/lock").
api_endpoint("lock", "GET", "/api/v1/planning/models/{modelId}/lock/status").

# =============================================================================
# Conflict Resolution
# =============================================================================

# Private publish conflicts
publish_conflict("PrivatePublishConflict", "None", "no_conflict").
publish_conflict("PrivatePublishConflict", "DataChanged", "data_modified").
publish_conflict("PrivatePublishConflict", "StructureChanged", "structure_modified").
publish_conflict("PrivatePublishConflict", "Deleted", "version_deleted").

# Public publish conflicts
publish_conflict("PublicPublishConflict", "None", "no_conflict").
publish_conflict("PublicPublishConflict", "NewerVersionExists", "newer_exists").
publish_conflict("PublicPublishConflict", "VersionLocked", "locked").
publish_conflict("PublicPublishConflict", "InsufficientPermissions", "no_permission").