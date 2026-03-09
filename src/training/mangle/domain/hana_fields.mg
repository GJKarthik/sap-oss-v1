# =============================================================================
# HANA Field Classification Rules (Mangle)
# Classifies Treasury, ESG, and NFRP fields for ODPS 4.1 data products.
# Pattern: same as data-cleaning-copilot mangle/a2a/mcp.mg
# =============================================================================

# --- Treasury/Capital Markets Fields ---
is_identifier_field("GLB_CUSIP").
is_identifier_field("GLB_ISIN").
is_identifier_field("GLB_INSTRUMENT").

is_measure_field("GLB_ASW_DM") :- field_annotation("GLB_ASW_DM", "@Analytics.Measure").
is_measure_field("GLB_BOOK_PRICE") :- field_annotation("GLB_BOOK_PRICE", "@Analytics.Measure").
is_measure_field("GLB_BOOK_VALUE_USD") :- field_annotation("GLB_BOOK_VALUE_USD", "@Analytics.Measure").
is_measure_field("GLB_CR_DELTA_TOTAL") :- field_annotation("GLB_CR_DELTA_TOTAL", "@Analytics.Measure").
is_measure_field("GLB_IR_PV01_TOTAL") :- field_annotation("GLB_IR_PV01_TOTAL", "@Analytics.Measure").
is_measure_field("GLB_MARKET_PRICE") :- field_annotation("GLB_MARKET_PRICE", "@Analytics.Measure").
is_measure_field("GLB_MARKET_VALUE_USD") :- field_annotation("GLB_MARKET_VALUE_USD", "@Analytics.Measure").
is_measure_field("GLB_MARKET_YIELD") :- field_annotation("GLB_MARKET_YIELD", "@Analytics.Measure").
is_measure_field("GLB_MTM_USD") :- field_annotation("GLB_MTM_USD", "@Analytics.Measure").
is_measure_field("GLB_NOTIONAL_USD") :- field_annotation("GLB_NOTIONAL_USD", "@Analytics.Measure").
is_measure_field("GLB_RWA") :- field_annotation("GLB_RWA", "@Analytics.Measure").
is_measure_field("GLB_YIELD_IMPACT") :- field_annotation("GLB_YIELD_IMPACT", "@Analytics.Measure").

is_dimension_field("GLB_ASSET_CLASS_2") :- field_annotation("GLB_ASSET_CLASS_2", "@Analytics.Dimension").
is_dimension_field("GLB_COUPON_TYPE") :- field_annotation("GLB_COUPON_TYPE", "@Analytics.Dimension").
is_dimension_field("GLB_FINAL_CCY").
is_dimension_field("GLB_FINAL_COUNTRY_NAME") :- field_annotation("GLB_FINAL_COUNTRY_NAME", "@Analytics.Dimension").
is_dimension_field("GLB_FV_HTC").
is_dimension_field("GLB_GLOBAL_REGION") :- field_annotation("GLB_GLOBAL_REGION", "@Analytics.Dimension").
is_dimension_field("GLB_HIGH_LVL_STRATEGY").
is_dimension_field("GLB_HQLA").
is_dimension_field("GLB_INDEX_NAME").
is_dimension_field("GLB_ISSUE_RATING_SP").
is_dimension_field("GLB_ISSUER_NAME").
is_dimension_field("GLB_MAP_PORTFOLIO").
is_dimension_field("GLB_PRODUCT_SUBTYPE").
is_dimension_field("GLB_SOLO_SUB").

is_date_field("GLB_LAST_RESET_DATE").
is_date_field("GLB_MATURITY_DATE").
is_date_field("GLB_REPORT_DATE").

# Business term aliases for Treasury
business_alias("MtM", "GLB_MTM_USD").
business_alias("MTM", "GLB_MTM_USD").
business_alias("mark to market", "GLB_MTM_USD").
business_alias("notional", "GLB_NOTIONAL_USD").
business_alias("nominal", "GLB_NOTIONAL_USD").
business_alias("RWA", "GLB_RWA").
business_alias("risk weighted assets", "GLB_RWA").
business_alias("market value", "GLB_MARKET_VALUE_USD").
business_alias("book value", "GLB_BOOK_VALUE_USD").
business_alias("PV01", "GLB_IR_PV01_TOTAL").
business_alias("CR01", "GLB_CR_DELTA_TOTAL").
business_alias("ASW", "GLB_ASW_DM").
business_alias("discount margin", "GLB_ASW_DM").

# --- ESG / Net Zero Fields ---
is_measure_field("EMIINTAL") :- field_annotation("EMIINTAL", "@Analytics.Measure").
is_measure_field("ATT_PROD") :- field_annotation("ATT_PROD", "@Analytics.Measure").
is_measure_field("ATT_EMI") :- field_annotation("ATT_EMI", "@Analytics.Measure").
is_measure_field("FEMISSSION_S12").
is_measure_field("F_EMISSION_S3").
is_measure_field("PE_ASS") :- field_annotation("PE_ASS", "@Analytics.Measure").
is_measure_field("TRYTDTR").
is_measure_field("RWAASSTR").
is_measure_field("RAHDR").
is_measure_field("PCAF_S12_SC").
is_measure_field("PCAFS3SC").
is_measure_field("EMI_INTENSITY").
is_measure_field("EVIC").
is_measure_field("ATTR_FACTOR").

is_dimension_field("ASSNAME").
is_dimension_field("ASSTY").
is_dimension_field("DD_SEC").
is_dimension_field("CLGRD").
is_dimension_field("BEBOOKINGLOCID").
is_dimension_field("C_SSEG_ID").
is_dimension_field("FoL_Location").
is_dimension_field("Management_Prod_Hier").
is_dimension_field("VAL_CH").
is_dimension_field("VCSCOPE").

is_identifier_field("ASSID").
is_date_field("CALMONTH").

business_alias("financed emission", "ATT_EMI").
business_alias("emission", "ATT_EMI").
business_alias("asset intensity", "EMIINTAL").
business_alias("exposure", "PE_ASS").
business_alias("cib pe asset", "PE_ASS").
business_alias("PCAF score", "PCAF_S12_SC").
business_alias("risk appetite headroom", "RAHDR").

# --- NFRP/BPC Performance Fields ---
is_dimension_field("ACCOUNT").
is_dimension_field("PRODUCT").
is_dimension_field("SEGMENT").
is_dimension_field("LOCATION_PK").
is_dimension_field("COST_CLUSTER_PK").
is_dimension_field("REPORTING").
is_dimension_field("VERSION").
is_dimension_field("SOLOSUB").
is_dimension_field("BOOKS").
is_dimension_field("MEMO_FLAG").

is_date_field("PERIOD_DATE").
is_date_field("MONTH").
is_date_field("YEAR").
is_date_field("MONTH_ABR").
is_date_field("MONTH_NUM").

# Hierarchy navigation rules
hierarchy_level("NFRP_Account_AM", "L0", "broadest").
hierarchy_level("NFRP_Account_AM", "L1", "secondary").
hierarchy_level("NFRP_Account_AM", "L2", "tertiary").
hierarchy_level("NFRP_Account_AM", "L3", "detail").
hierarchy_level("NFRP_Account_AM", "L4", "fine").
hierarchy_level("NFRP_Account_AM", "L5", "granular").

hierarchy_level("NFRP_Location_AM", "L0", "broadest").
hierarchy_level("NFRP_Location_AM", "L1", "regional").
hierarchy_level("NFRP_Location_AM", "L2", "sub-regional").
hierarchy_level("NFRP_Location_AM", "L3", "country").
hierarchy_level("NFRP_Location_AM", "L4", "sub-country").
hierarchy_level("NFRP_Location_AM", "L5", "city").
hierarchy_level("NFRP_Location_AM", "L6", "granular").

# Data product → ai-core-pal routing
route_to_pal(Product, Function) :-
    data_product(Product),
    pal_function(Function),
    security_class(Product, "confidential"),
    routing_policy(Product, "vllm-only").

# All HANA training data products are confidential
security_class("treasury-capital-markets-v1", "confidential").
security_class("esg-sustainability-v1", "confidential").
security_class("performance-bpc-v1", "confidential").
security_class("staging-schema-v1", "confidential").

routing_policy(Product, "vllm-only") :- security_class(Product, "confidential").

# Field annotation generation
field_annotation(Field, "@Analytics.Measure") :- is_measure_field(Field).
field_annotation(Field, "@Analytics.Dimension") :- is_dimension_field(Field).

# Suggest annotation for field classification queries
suggest_finance_annotation(Field, "@Analytics.Measure") :- is_measure_field(Field).
suggest_finance_annotation(Field, "@Analytics.Dimension") :- is_dimension_field(Field).
suggest_finance_annotation(Field, "@Common.Label") :- business_alias(_, Field).

