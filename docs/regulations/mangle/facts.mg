# Regulations RAG - Mangle Facts Schema
# Machine-readable facts extracted from regulatory documents
# Generated from RAG chunks in /regulations/machine-readable/

# =============================================================================
# SOURCE DOCUMENTS
# =============================================================================
# Metadata about the source regulatory documents

Decl source_document(
  source_id: string,
  title: string,
  document_type: string,
  pages: integer,
  chunk_count: integer,
  publication_date: string,
  publisher: string
).

source_document(
  "2025-AI-Agent-Index",
  "The 2025 AI Agent Index: Documenting Technical and Safety Features of Deployed Agentic AI Systems",
  "index",
  39,
  112,
  "2025-12-31",
  "MIT/Cambridge/Stanford/Harvard"
).

source_document(
  "mgf-for-agentic-ai",
  "Model AI Governance Framework for Agentic AI",
  "framework",
  29,
  64,
  "2026-01-22",
  "Singapore IMDA"
).

source_document(
  "2503.18238v3",
  "Collaborating with AI Agents: A Field Experiment on Teamwork, Productivity, and Performance",
  "research",
  59,
  106,
  "2026-02-06",
  "Johns Hopkins/MIT Sloan"
).

# =============================================================================
# CHUNK SCHEMA
# =============================================================================
# Each RAG chunk is represented as a single fact

Decl chunk(
  chunk_id: string,
  source_pdf: string,
  page_start: integer,
  page_end: integer,
  chunk_index: integer,
  word_count: integer,
  text: string
).

# =============================================================================
# CHUNK METADATA
# =============================================================================
# Additional metadata for chunk classification

Decl chunk_topic(
  chunk_id: string,
  topic: string
).

Decl chunk_contains_requirement(
  chunk_id: string,
  requirement_type: string
).

Decl chunk_mentions_agent(
  chunk_id: string,
  agent_name: string
).

Decl chunk_mentions_risk(
  chunk_id: string,
  risk_type: string
).