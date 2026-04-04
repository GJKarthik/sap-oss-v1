# ============================================================
# ODPS (Open Data Product Standard) Compliance Rules
# Blanket AI Safety Governance - Data Product Governance
# 
# This file implements the ODPS compliance checking system
# that ensures no data product is deployed without meeting
# all governance requirements.
#
# Reference: safety-ai-governance.pdf Section 5
# ============================================================

# Package declaration
package odps_compliance;

# ------------------------------------------------------------
# NINE COMPLETENESS PREDICATES
# ------------------------------------------------------------
# A data product must have all nine artifacts to be compliant:
# 1. Rules (business logic rules)
# 2. Controls (governance controls)
# 3. Thresholds (quality thresholds)
# 4. Implementation (code implementation)
# 5. Service (service binding)
# 6. Schema (data schema)
# 7. Documentation (docs)
# 8. Tests (test cases)
# 9. UI (user interface)

missing_rules(Id) :- 
    data_product(Id, _, _, _), 
    not odps_rule(Id, _).

missing_controls(Id) :- 
    data_product(Id, _, _, _), 
    not doi_control(Id, _).

missing_thresholds(Id) :- 
    data_product(Id, _, _, _), 
    not doi_threshold(Id, _).

missing_impl(Id) :- 
    data_product(Id, _, _, _), 
    not implemented_by(Id, _).

missing_service(Id) :- 
    data_product(Id, _, _, _), 
    not served_by(Id, _).

missing_schema(Id) :- 
    data_product(Id, _, _, _), 
    not schema_spec(Id, _).

missing_docs(Id) :- 
    data_product(Id, _, _, _), 
    not documented_by(Id, _).

missing_tests(Id) :- 
    data_product(Id, _, _, _), 
    not tested_by(Id, _).

missing_ui(Id) :- 
    data_product(Id, _, _, _), 
    not displayed_by(Id, _).

# ------------------------------------------------------------
# ODPS INCOMPLETE AGGREGATION
# ------------------------------------------------------------

odps_incomplete(Id, "no_rules") :- missing_rules(Id).
odps_incomplete(Id, "no_controls") :- missing_controls(Id).
odps_incomplete(Id, "no_thresholds") :- missing_thresholds(Id).
odps_incomplete(Id, "no_impl") :- missing_impl(Id).
odps_incomplete(Id, "no_service") :- missing_service(Id).
odps_incomplete(Id, "no_schema") :- missing_schema(Id).
odps_incomplete(Id, "no_docs") :- missing_docs(Id).
odps_incomplete(Id, "no_tests") :- missing_tests(Id).
odps_incomplete(Id, "no_ui") :- missing_ui(Id).

# ------------------------------------------------------------
# ODPS COMPLIANT CHECK
# ------------------------------------------------------------

# A data product is ODPS compliant if none of the incomplete checks fire
odps_compliant(Id) :-
    data_product(Id, _, _, _),
    not odps_incomplete(Id, _).

# Count of missing artifacts
odps_missing_count(Id, Count) :-
    data_product(Id, _, _, _),
    odps_incomplete(Id, _)
    |> do fn:group_by(Id),
    let Count = fn:count(_).

# Compliance score (0-9, 9 = fully compliant)
odps_compliance_score(Id, Score) :-
    data_product(Id, _, _, _),
    odps_missing_count(Id, Missing),
    Score = 9 - Missing.

odps_compliance_score(Id, 9) :-
    data_product(Id, _, _, _),
    odps_compliant(Id).

# ------------------------------------------------------------
# APP-LEVEL COMPLIANCE (Additional Requirements)
# ------------------------------------------------------------

# Applications have additional requirements beyond base ODPS
#
# petri_stage(App, Stage) is NOT defined here: it is supplied at runtime by the
# Colored Petri Net engine in @sap-ai-sdk/mcp-server (orchestration_run on
# odps_close_process, cpn_reset/cpn_fire/cpn_step). Export those facts into the
# Mangle fact store or query mangle_query(predicate="petri_stage") over MCP.
# Example static fact for offline tests only:
#   petri_stage("example_app", "S02").

odps_incomplete(App, "no_api_endpoints") :-
    data_product(App, _, "application", _),
    not api_endpoint(App, _, _, _).

odps_incomplete(App, "no_maker_checker") :-
    data_product(App, _, "application", _),
    not odps_rule(App, "maker_checker").

odps_incomplete(App, "no_close_process") :-
    data_product(App, _, "application", _),
    not petri_stage(App, "S02").

odps_incomplete(App, "no_audit_trail") :-
    data_product(App, _, "application", _),
    not audit_enabled(App).

# App-level compliance requires all base ODPS plus app-specific
odps_compliant_app(App) :-
    odps_compliant(App),
    data_product(App, _, "application", _),
    api_endpoint(App, _, _, _),
    odps_rule(App, "maker_checker").

# ------------------------------------------------------------
# DOI (Document of Instructions) VALIDATION
# ------------------------------------------------------------

# DOI sections required
doi_required_section("overview").
doi_required_section("data_sources").
doi_required_section("transformations").
doi_required_section("quality_controls").
doi_required_section("access_controls").
doi_required_section("monitoring").
doi_required_section("change_management").

# Check for missing DOI sections
doi_missing_section(Id, Section) :-
    data_product(Id, _, _, _),
    doi_required_section(Section),
    not doi_section(Id, Section, _).

# DOI section completeness
doi_sections_complete(Id) :-
    data_product(Id, _, _, _),
    not doi_missing_section(Id, _).

# DOI validation score (5 dimensions)
# 1. Section completeness
# 2. Field completeness
# 3. Threshold validation
# 4. Process step validation
# 5. Consistency validation

doi_section_score(Id, Score) :-
    data_product(Id, _, _, _),
    doi_section(Id, _, _)
    |> do fn:group_by(Id),
    let Present = fn:count(_),
    let Total = 7,
    Score = Present / Total.

doi_validation_score(Id, Score) :-
    data_product(Id, _, _, _),
    doi_section_score(Id, S1),
    doi_field_score(Id, S2),
    doi_threshold_score(Id, S3),
    doi_process_score(Id, S4),
    doi_consistency_score(Id, S5),
    Score = (S1 + S2 + S3 + S4 + S5) / 5.

# DOI status derived from score
doi_status(Id, "VALID") :-
    doi_validation_score(Id, Score),
    Score >= 0.9.

doi_status(Id, "WARNING") :-
    doi_validation_score(Id, Score),
    Score >= 0.7,
    Score < 0.9.

doi_status(Id, "INVALID") :-
    doi_validation_score(Id, Score),
    Score < 0.7.

# ------------------------------------------------------------
# PIPELINE TRACEABILITY
# ------------------------------------------------------------

# Five traceability checks
missing_doc(P) :- 
    data_product(P, _, _, _), 
    not documented_by(P, _).

missing_pipeline(P) :- 
    data_product(P, _, _, _), 
    not pipeline_spec(P, _).

missing_deploy(P) :- 
    data_product(P, _, _, _), 
    not deployment_spec(P, _).

missing_runtime(P) :- 
    data_product(P, _, _, _), 
    not runtime_status(P, _).

# Full traceability
traceable(P) :-
    data_product(P, _, _, _),
    not missing_doc(P),
    not missing_impl(P),
    not missing_pipeline(P),
    not missing_deploy(P),
    not missing_runtime(P).

# Pipeline health
run_healthy(P) :-
    pipeline_run(P, RunId, "success", _),
    latest_run(P, RunId).

run_unhealthy(P, Reason) :-
    pipeline_run(P, RunId, Status, _),
    latest_run(P, RunId),
    Status != "success",
    Reason = Status.

# Operational readiness
operational(P) :-
    traceable(P),
    run_healthy(P).

# ------------------------------------------------------------
# DEPLOYMENT READINESS
# ------------------------------------------------------------

# Quality gates
quality_gate_passed(P, "odps") :- odps_compliant(P).
quality_gate_passed(P, "doi") :- doi_status(P, "VALID").
quality_gate_passed(P, "doi") :- doi_status(P, "WARNING").
quality_gate_passed(P, "traceability") :- traceable(P).
quality_gate_passed(P, "testing") :- tested_by(P, _), test_passed(P).

quality_gate_failed(P, Gate) :-
    data_product(P, _, _, _),
    required_gate(Gate),
    not quality_gate_passed(P, Gate).

# Required gates for deployment
required_gate("odps").
required_gate("doi").
required_gate("traceability").
required_gate("testing").

# All quality gates passed
quality_gates_passed(P) :-
    data_product(P, _, _, _),
    not quality_gate_failed(P, _).

# Pipeline ready for deployment
pipeline_ready_for_deployment(P) :-
    operational(P),
    quality_gates_passed(P).

# ------------------------------------------------------------
# COMPLIANCE ALERTS
# ------------------------------------------------------------

alert_odps_violation(Id, Missing, "warning") :-
    odps_incomplete(Id, Missing).

alert_doi_invalid(Id, "critical") :-
    doi_status(Id, "INVALID").

alert_pipeline_unhealthy(Id, Reason, "critical") :-
    run_unhealthy(Id, Reason).

alert_not_deployable(Id, Gate, "critical") :-
    quality_gate_failed(Id, Gate).

# ------------------------------------------------------------
# BLANKET CONTROL INVARIANT
# ------------------------------------------------------------

# No data product deployed without compliance
non_compliant_deployment(Id) :-
    deployment_spec(Id, _),
    not odps_compliant(Id).

# Assertion: blanket control holds for data products
data_product_blanket_control_violated :-
    non_compliant_deployment(_).

data_product_blanket_control_enforced :-
    not data_product_blanket_control_violated.