# Regulations RAG - Mangle Rules
# Derived predicates for querying and analyzing regulatory chunks
# Generated from /regulations/machine-readable/

# =============================================================================
# CHUNK QUERIES
# =============================================================================

# Get all chunks from a specific source document
Decl chunks_from_source(chunk_id: string, text: string) :-
  chunk(chunk_id, source_pdf, _, _, _, _, text),
  source_document(source_id, _, _, _, _, _, _),
  fn:contains(source_pdf, source_id).

# Get chunk by page range
Decl chunk_on_page(chunk_id: string, source_pdf: string, page: integer) :-
  chunk(chunk_id, source_pdf, page_start, page_end, _, _, _),
  page >= page_start,
  page <= page_end.

# Count chunks per source
Decl chunk_count_by_source(source_pdf: string, count: integer) :-
  count = count { chunk(_, source_pdf, _, _, _, _, _) }.

# =============================================================================
# TEXT SEARCH RULES
# =============================================================================

# Find chunks containing a keyword
Decl chunk_contains_keyword(chunk_id: string, keyword: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(fn:lower(text), fn:lower(keyword)).

# Find chunks mentioning governance requirements (must/shall/should)
Decl chunk_has_requirement(chunk_id: string, obligation_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(text, " must "),
  obligation_type = "must".

Decl chunk_has_requirement(chunk_id: string, obligation_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(text, " shall "),
  obligation_type = "shall".

Decl chunk_has_requirement(chunk_id: string, obligation_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(text, " should "),
  obligation_type = "should".

# Find chunks mentioning specific risk types
Decl chunk_mentions_risk_type(chunk_id: string, risk_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(fn:lower(text), "safety"),
  risk_type = "safety".

Decl chunk_mentions_risk_type(chunk_id: string, risk_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(fn:lower(text), "security"),
  risk_type = "security".

Decl chunk_mentions_risk_type(chunk_id: string, risk_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(fn:lower(text), "accountability"),
  risk_type = "accountability".

Decl chunk_mentions_risk_type(chunk_id: string, risk_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(fn:lower(text), "transparency"),
  risk_type = "transparency".

Decl chunk_mentions_risk_type(chunk_id: string, risk_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(fn:lower(text), "autonomy"),
  risk_type = "autonomy".

# =============================================================================
# GOVERNANCE FRAMEWORK RULES
# =============================================================================

# Identify MGF governance dimensions from chunks
Decl governance_dimension(chunk_id: string, dimension: string) :-
  chunk(chunk_id, "mgf-for-agentic-ai.pdf", _, _, _, _, text),
  fn:contains(fn:lower(text), "assess and bound the risks"),
  dimension = "risk_assessment".

Decl governance_dimension(chunk_id: string, dimension: string) :-
  chunk(chunk_id, "mgf-for-agentic-ai.pdf", _, _, _, _, text),
  fn:contains(fn:lower(text), "humans meaningfully accountable"),
  dimension = "accountability".

Decl governance_dimension(chunk_id: string, dimension: string) :-
  chunk(chunk_id, "mgf-for-agentic-ai.pdf", _, _, _, _, text),
  fn:contains(fn:lower(text), "technical controls"),
  dimension = "technical_controls".

Decl governance_dimension(chunk_id: string, dimension: string) :-
  chunk(chunk_id, "mgf-for-agentic-ai.pdf", _, _, _, _, text),
  fn:contains(fn:lower(text), "end-user responsibility"),
  dimension = "user_responsibility".

# =============================================================================
# AGENT INDEX RULES
# =============================================================================

# Identify agent categories from chunks
Decl agent_category_chunk(chunk_id: string, category: string) :-
  chunk(chunk_id, "2025-AI-Agent-Index.pdf", _, _, _, _, text),
  fn:contains(fn:lower(text), "browser agent"),
  category = "browser".

Decl agent_category_chunk(chunk_id: string, category: string) :-
  chunk(chunk_id, "2025-AI-Agent-Index.pdf", _, _, _, _, text),
  fn:contains(fn:lower(text), "chat agent"),
  category = "chat".

Decl agent_category_chunk(chunk_id: string, category: string) :-
  chunk(chunk_id, "2025-AI-Agent-Index.pdf", _, _, _, _, text),
  fn:contains(fn:lower(text), "enterprise agent"),
  category = "enterprise".

# Identify autonomy level mentions
Decl autonomy_level_chunk(chunk_id: string, level: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(text, "L1"),
  level = "L1".

Decl autonomy_level_chunk(chunk_id: string, level: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(text, "L2"),
  level = "L2".

Decl autonomy_level_chunk(chunk_id: string, level: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(text, "L3"),
  level = "L3".

Decl autonomy_level_chunk(chunk_id: string, level: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(text, "L4"),
  level = "L4".

Decl autonomy_level_chunk(chunk_id: string, level: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(text, "L5"),
  level = "L5".

# =============================================================================
# RESEARCH FINDINGS RULES
# =============================================================================

# Identify collaboration findings from research paper
Decl collaboration_finding_chunk(chunk_id: string, finding_type: string) :-
  chunk(chunk_id, "2503.18238v3.pdf", _, _, _, _, text),
  fn:contains(fn:lower(text), "productivity"),
  finding_type = "productivity".

Decl collaboration_finding_chunk(chunk_id: string, finding_type: string) :-
  chunk(chunk_id, "2503.18238v3.pdf", _, _, _, _, text),
  fn:contains(fn:lower(text), "delegation"),
  finding_type = "delegation".

Decl collaboration_finding_chunk(chunk_id: string, finding_type: string) :-
  chunk(chunk_id, "2503.18238v3.pdf", _, _, _, _, text),
  fn:contains(fn:lower(text), "diversity"),
  finding_type = "diversity".

Decl collaboration_finding_chunk(chunk_id: string, finding_type: string) :-
  chunk(chunk_id, "2503.18238v3.pdf", _, _, _, _, text),
  fn:contains(fn:lower(text), "quality"),
  finding_type = "quality".

# =============================================================================
# SAFETY AND CONTROL RULES
# =============================================================================

# Find chunks discussing safety controls
Decl safety_control_chunk(chunk_id: string, control_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(fn:lower(text), "guardrail"),
  control_type = "guardrails".

Decl safety_control_chunk(chunk_id: string, control_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(fn:lower(text), "sandbox"),
  control_type = "sandboxing".

Decl safety_control_chunk(chunk_id: string, control_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(fn:lower(text), "approval"),
  control_type = "approval_gates".

Decl safety_control_chunk(chunk_id: string, control_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(fn:lower(text), "monitoring"),
  control_type = "monitoring".

Decl safety_control_chunk(chunk_id: string, control_type: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(fn:lower(text), "emergency stop"),
  control_type = "emergency_stop".

# Find chunks discussing human oversight
Decl human_oversight_chunk(chunk_id: string) :-
  chunk(chunk_id, _, _, _, _, _, text),
  fn:contains(fn:lower(text), "human oversight");
  fn:contains(fn:lower(text), "human-in-the-loop");
  fn:contains(fn:lower(text), "human approval").

# =============================================================================
# AGGREGATE QUERIES
# =============================================================================

# Count chunks by document type
Decl document_type_summary(document_type: string, count: integer) :-
  source_document(_, _, document_type, _, chunk_count, _, _),
  count = chunk_count.

# Find all governance-related chunks
Decl governance_chunk(chunk_id: string) :-
  chunk_has_requirement(chunk_id, _);
  governance_dimension(chunk_id, _);
  human_oversight_chunk(chunk_id).

# Find all safety-related chunks
Decl safety_chunk(chunk_id: string) :-
  chunk_mentions_risk_type(chunk_id, "safety");
  safety_control_chunk(chunk_id, _).

# =============================================================================
# CROSS-DOCUMENT ANALYSIS
# =============================================================================

# Find related chunks across documents by topic
Decl related_chunks(chunk_id_1: string, chunk_id_2: string, topic: string) :-
  chunk(chunk_id_1, source_1, _, _, _, _, _),
  chunk(chunk_id_2, source_2, _, _, _, _, _),
  source_1 != source_2,
  chunk_mentions_risk_type(chunk_id_1, topic),
  chunk_mentions_risk_type(chunk_id_2, topic).

# Find MGF requirements relevant to agent index findings
Decl mgf_for_agent_finding(mgf_chunk_id: string, index_chunk_id: string, topic: string) :-
  chunk(mgf_chunk_id, "mgf-for-agentic-ai.pdf", _, _, _, _, _),
  chunk(index_chunk_id, "2025-AI-Agent-Index.pdf", _, _, _, _, _),
  chunk_mentions_risk_type(mgf_chunk_id, topic),
  chunk_mentions_risk_type(index_chunk_id, topic).