# Summary: Simula Training Data Framework Specification
**Reference:** SIM-TRAIN-2026-v1.2  
**Target Persona:** Training Engineer

## 1. Executive Vision
The Simula domain provides the high-quality synthetic training data required to achieve "Ground Truth" performance in the platform's Text-to-SQL tasks. It implements the Simula methodology—extracting actual SAP HANA Cloud schemas and using reasoning-driven agents to generate complex, multi-join query taxonomies that reflect real enterprise data structures.

## 2. Core Algorithms & Pipeline
- **Algorithm 1 (Taxonomy Generation):** Uses a reasoning-driven breadth-first expansion to identify query factors and propose a best-of-N taxonomic structure.
- **Algorithm 2 (Agentic Data Synthesis):** Uses a double-critic validation loop (LLM Critic A and Critic B) to synthesize training examples that pass a calibrated complexity score (Algorithm 3: Elo).
- **HANA Extraction Pipeline:** Connects directly to HANA Cloud to capture metadata for Global Temporary and Row-Store tables, ensuring the synthetic data is schema-accurate.

## 3. Operational Safety & FMEA
The Simula FMEA addresses the critical risk of **Critic Collusion** (where both validation critics pass a low-quality query). The technical mitigation is the injection of a "Gold Standard" probe query every 100 samples to verify the critics' own calibration.

**Registry Integrity ADR:** Mandates that the Simula agent must halt if the local codebase's schema registry is out of sync with the live HANA Cloud environment.

## 4. Implementation Manifest
- **Wave 1:** Implement the HANA Schema Extraction Pipeline (MCP discovery and column extraction).
- **Wave 2:** Realize Algorithm 1 (Taxonomy Generation) and Algorithm 2 (Agentic Synthesis).
- **Wave 3:** Deliver test fixtures and achieve 85% line coverage on the evaluation framework.

## 5. Governance & Global Role
Simula is the "Training Backbone" of the platform. It provides the training corpus used by Arabic AP (for field extraction) and Trial Balance (for anomaly detection). It is read-only regarding other domains; it consumes their schemas as input and produces `TrainingExample` records as output.

---
*End of Summary.*
