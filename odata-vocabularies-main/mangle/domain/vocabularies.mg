# OData Vocabularies - Mangle Facts for Reasoning Engine
# Auto-generated structure for vocabulary-based reasoning
# 
# This file defines predicates and rules for working with OData vocabulary terms
# in the Mangle reasoning engine. The actual facts are loaded dynamically
# from the MCP server via the mangle://facts resource.

# =============================================================================
# Predicate Declarations
# =============================================================================

Decl vocabulary(Name, Namespace) descr [extensional()].
Decl term(Vocabulary, Name, Type, Description) descr [extensional()].
Decl term_applies_to(Vocabulary, Term, Target) descr [extensional()].
Decl term_experimental(Vocabulary, Term) descr [extensional()].
Decl term_deprecated(Vocabulary, Term) descr [extensional()].
Decl complex_type(Vocabulary, Name) descr [extensional()].
Decl type_property(Vocabulary, Type, Property, PropertyType) descr [extensional()].
Decl enum_type(Vocabulary, Name) descr [extensional()].
Decl enum_member(Vocabulary, Type, Member) descr [extensional()].
Decl entity_config(EntityType, KeyProperty, TextProperty, Namespace) descr [extensional()].

# =============================================================================
# Derived Predicates - Term Classification
# =============================================================================

# A term is stable if it's not experimental and not deprecated
is_stable_term(Vocabulary, Term) :-
    term(Vocabulary, Term, _, _),
    !term_experimental(Vocabulary, Term),
    !term_deprecated(Vocabulary, Term).

# Check if a term can be applied to a specific target
can_apply_term(Vocabulary, Term, Target) :-
    term(Vocabulary, Term, _, _),
    term_applies_to(Vocabulary, Term, Target).

# Term is applicable to all targets (no AppliesTo restriction)
can_apply_term_anywhere(Vocabulary, Term) :-
    term(Vocabulary, Term, _, _),
    !term_applies_to(Vocabulary, Term, _).

# =============================================================================
# Derived Predicates - Analytics
# =============================================================================

# Property is analytical (dimension or measure)
is_analytical_term(Term) :-
    term("Analytics", Term, _, _).

is_dimension_term(Term) :-
    term("Analytics", Term, _, _),
    Term = "Dimension".

is_measure_term(Term) :-
    term("Analytics", Term, _, _),
    Term = "Measure".

is_measure_term(Term) :-
    term("Analytics", Term, _, _),
    Term = "AccumulativeMeasure".

# =============================================================================
# Derived Predicates - UI
# =============================================================================

# Term is a UI presentation term
is_ui_presentation_term(Term) :-
    term("UI", Term, _, _).

is_chart_term(Term) :-
    term("UI", Term, _, Description),
    Description :> match("(?i)chart").

is_table_term(Term) :-
    term("UI", Term, _, _),
    Term = "LineItem".

is_form_term(Term) :-
    term("UI", Term, _, _),
    Term = "FieldGroup".

# =============================================================================
# Derived Predicates - Personal Data (GDPR)
# =============================================================================

# Term indicates personal data handling
is_personal_data_term(Term) :-
    term("PersonalData", Term, _, _).

is_sensitive_data_term(Term) :-
    term("PersonalData", Term, _, _),
    Term = "IsPotentiallySensitive".

is_pii_term(Term) :-
    term("PersonalData", Term, _, _),
    Term = "IsPotentiallyPersonal".

# =============================================================================
# Derived Predicates - Common Terms
# =============================================================================

# Semantic identification terms
is_semantic_term(Term) :-
    term("Common", Term, _, _),
    Term :> match("(?i)semantic").

# Label/text terms for display
is_display_term(Term) :-
    term("Common", Term, _, _),
    (Term = "Label"; Term = "Heading"; Term = "QuickInfo"; Term = "Text").

# Value list terms for reference data
is_valuelist_term(Term) :-
    term("Common", Term, _, _),
    Term :> match("(?i)valuelist").

# Calendar/temporal terms
is_calendar_term(Term) :-
    term("Common", Term, _, _),
    Term :> match("(?i)calendar").

is_fiscal_term(Term) :-
    term("Common", Term, _, _),
    Term :> match("(?i)fiscal").

# Draft handling terms
is_draft_term(Term) :-
    term("Common", Term, _, _),
    Term :> match("(?i)draft").

# =============================================================================
# Derived Predicates - Entity Extraction
# =============================================================================

# Check if query matches an entity config
has_entity_config(EntityType) :-
    entity_config(EntityType, _, _, _).

# Get text property for entity display
entity_text_property(EntityType, TextProperty) :-
    entity_config(EntityType, _, TextProperty, _).

# Get key property for entity identification
entity_key_property(EntityType, KeyProperty) :-
    entity_config(EntityType, KeyProperty, _, _).

# Get namespace for entity
entity_namespace(EntityType, Namespace) :-
    entity_config(EntityType, _, _, Namespace).

# =============================================================================
# Derived Predicates - Vocabulary Statistics
# =============================================================================

# Count terms in vocabulary (aggregation would need engine support)
has_terms(Vocabulary) :-
    term(Vocabulary, _, _, _).

has_complex_types(Vocabulary) :-
    complex_type(Vocabulary, _).

has_enum_types(Vocabulary) :-
    enum_type(Vocabulary, _).

# =============================================================================
# Rules for Query Resolution
# =============================================================================

# Determine if query involves analytical concepts
query_is_analytical(Query) :-
    Query :> match("(?i)(dimension|measure|sum|count|average|total|aggregate)").

# Determine if query involves UI concepts
query_is_ui_related(Query) :-
    Query :> match("(?i)(chart|table|form|field|column|ui|display|show)").

# Determine if query involves personal data
query_involves_personal_data(Query) :-
    Query :> match("(?i)(personal|sensitive|gdpr|pii|customer|employee|name|address|email)").

# Determine if query is about vocabulary itself
query_is_vocabulary_meta(Query) :-
    Query :> match("(?i)(vocabulary|term|annotation|odata|csdl)").

# =============================================================================
# Integration Rules for Mangle Query Service
# =============================================================================

# Route analytical queries to HANA
should_route_to_hana(Query) :-
    query_is_analytical(Query).

# Apply GDPR masking for personal data queries
should_apply_gdpr_mask(Query) :-
    query_involves_personal_data(Query).

# Route vocabulary meta queries to MCP server
should_route_to_vocabulary_service(Query) :-
    query_is_vocabulary_meta(Query).

# =============================================================================
# Example Static Facts (can be overridden by dynamic loading)
# =============================================================================

# Core vocabularies
vocabulary("Common", "com.sap.vocabularies.Common.v1").
vocabulary("UI", "com.sap.vocabularies.UI.v1").
vocabulary("Analytics", "com.sap.vocabularies.Analytics.v1").
vocabulary("PersonalData", "com.sap.vocabularies.PersonalData.v1").
vocabulary("Hierarchy", "com.sap.vocabularies.Hierarchy.v1").
vocabulary("Communication", "com.sap.vocabularies.Communication.v1").
vocabulary("DataIntegration", "com.sap.vocabularies.DataIntegration.v1").

# Key terms
term("Common", "Label", "Edm.String", "A short, human-readable text suitable for labels").
term("Common", "Text", "Edm.String", "A descriptive text for values of the annotated property").
term("Common", "SemanticObject", "Edm.String", "Name of the Semantic Object").
term("Analytics", "Dimension", "Core.Tag", "Property holds the key of a dimension").
term("Analytics", "Measure", "Core.Tag", "Property holds the numeric value of a measure").
term("UI", "LineItem", "Collection(UI.DataFieldAbstract)", "Collection of data fields for table columns").
term("UI", "Chart", "UI.ChartDefinitionType", "Visualization of data").
term("PersonalData", "IsPotentiallyPersonal", "Core.Tag", "Property may contain personal data").
term("PersonalData", "IsPotentiallySensitive", "Core.Tag", "Property may contain sensitive personal data").

# Entity configurations for extraction
entity_config("SalesOrder", "SalesOrderID", "SalesOrderDescription", "com.sap.gateway.srvd.c_salesorder_srv").
entity_config("BusinessPartner", "BusinessPartner", "BusinessPartnerFullName", "com.sap.gateway.srvd.c_businesspartner_srv").
entity_config("Material", "Material", "MaterialDescription", "com.sap.gateway.srvd.c_material_srv").
entity_config("PurchaseOrder", "PurchaseOrderID", "PurchaseOrderDescription", "com.sap.gateway.srvd.c_purchaseorder_srv").
entity_config("Employee", "EmployeeID", "EmployeeName", "com.sap.gateway.srvd.c_employee_srv").
entity_config("CostCenter", "CostCenter", "CostCenterName", "com.sap.gateway.srvd.c_costcenter_srv").