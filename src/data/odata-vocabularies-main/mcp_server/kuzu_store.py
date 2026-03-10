# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
KùzuDB Graph-RAG store for odata-vocabularies MCP server.

Schema:
  Nodes  : ODataVocabulary, VocabularyTerm, AnnotationTarget
  Edges  : DEFINES_TERM   (ODataVocabulary → VocabularyTerm)
           ANNOTATES       (AnnotationTarget → VocabularyTerm)
           RELATED_VOCAB   (ODataVocabulary → ODataVocabulary)

Gracefully degrades when the `kuzu` Python package is not installed.
"""
from __future__ import annotations

import os
from typing import Any


class KuzuStore:
    """Embedded KùzuDB graph store for OData vocabulary entity relationships."""

    def __init__(self, db_path: str = ".kuzu-odata-vocab") -> None:
        self._db_path = db_path
        self._db: Any = None
        self._conn: Any = None
        self._available: bool = False
        self._schema_ready: bool = False
        self._init()

    def _init(self) -> None:
        try:
            import kuzu  # type: ignore[import]
            self._db = kuzu.Database(self._db_path)
            self._conn = kuzu.Connection(self._db)
            self._available = True
        except Exception:
            self._available = False

    def available(self) -> bool:
        return self._available

    # ------------------------------------------------------------------
    # Schema
    # ------------------------------------------------------------------

    def ensure_schema(self) -> None:
        if not self._available or not self._conn or self._schema_ready:
            return

        ddl = [
            # Node tables
            """CREATE NODE TABLE IF NOT EXISTS ODataVocabulary (
                vocabId    STRING,
                name       STRING,
                namespace  STRING,
                alias      STRING,
                status     STRING,
                PRIMARY KEY (vocabId)
            )""",
            """CREATE NODE TABLE IF NOT EXISTS VocabularyTerm (
                termId     STRING,
                name       STRING,
                type       STRING,
                appliesTo  STRING,
                description STRING,
                PRIMARY KEY (termId)
            )""",
            """CREATE NODE TABLE IF NOT EXISTS AnnotationTarget (
                targetId     STRING,
                entityType   STRING,
                namespace    STRING,
                usedInVocab  STRING,
                PRIMARY KEY (targetId)
            )""",
            # Relationship tables
            """CREATE REL TABLE IF NOT EXISTS DEFINES_TERM (
                FROM ODataVocabulary TO VocabularyTerm
            )""",
            """CREATE REL TABLE IF NOT EXISTS ANNOTATES (
                FROM AnnotationTarget TO VocabularyTerm
            )""",
            """CREATE REL TABLE IF NOT EXISTS RELATED_VOCAB (
                FROM ODataVocabulary TO ODataVocabulary
            )""",
        ]

        for stmt in ddl:
            self._conn.execute(stmt)

        self._schema_ready = True

    # ------------------------------------------------------------------
    # Upsert helpers
    # ------------------------------------------------------------------

    def upsert_vocabulary(
        self,
        vocab_id: str,
        name: str,
        namespace: str,
        alias: str,
        status: str,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (v:ODataVocabulary {vocabId: $id}) "
            "ON MATCH SET v.name = $nm, v.namespace = $ns, v.alias = $al, v.status = $st "
            "ON CREATE SET v.name = $nm, v.namespace = $ns, v.alias = $al, v.status = $st",
            {"id": vocab_id, "nm": name, "ns": namespace, "al": alias, "st": status},
        )

    def upsert_term(
        self,
        term_id: str,
        name: str,
        type_: str,
        applies_to: str,
        description: str,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (t:VocabularyTerm {termId: $id}) "
            "ON MATCH SET t.name = $nm, t.type = $ty, t.appliesTo = $ap, t.description = $dc "
            "ON CREATE SET t.name = $nm, t.type = $ty, t.appliesTo = $ap, t.description = $dc",
            {"id": term_id, "nm": name, "ty": type_, "ap": applies_to, "dc": description},
        )

    def upsert_annotation_target(
        self,
        target_id: str,
        entity_type: str,
        namespace: str,
        used_in_vocab: str,
    ) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MERGE (a:AnnotationTarget {targetId: $id}) "
            "ON MATCH SET a.entityType = $et, a.namespace = $ns, a.usedInVocab = $uv "
            "ON CREATE SET a.entityType = $et, a.namespace = $ns, a.usedInVocab = $uv",
            {"id": target_id, "et": entity_type, "ns": namespace, "uv": used_in_vocab},
        )

    # ------------------------------------------------------------------
    # Link helpers
    # ------------------------------------------------------------------

    def link_vocab_term(self, vocab_id: str, term_id: str) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (v:ODataVocabulary {vocabId: $vid}), (t:VocabularyTerm {termId: $tid}) "
            "MERGE (v)-[:DEFINES_TERM]->(t)",
            {"vid": vocab_id, "tid": term_id},
        )

    def link_target_term(self, target_id: str, term_id: str) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (a:AnnotationTarget {targetId: $aid}), (t:VocabularyTerm {termId: $tid}) "
            "MERGE (a)-[:ANNOTATES]->(t)",
            {"aid": target_id, "tid": term_id},
        )

    def link_vocabs(self, from_id: str, to_id: str) -> None:
        if not self._available or not self._conn:
            return
        self._conn.execute(
            "MATCH (a:ODataVocabulary {vocabId: $from}), (b:ODataVocabulary {vocabId: $to}) "
            "MERGE (a)-[:RELATED_VOCAB]->(b)",
            {"from": from_id, "to": to_id},
        )

    # ------------------------------------------------------------------
    # Query helpers
    # ------------------------------------------------------------------

    def run_query(self, cypher: str, params: dict | None = None) -> list[dict]:
        if not self._available or not self._conn:
            return []
        try:
            result = self._conn.execute(cypher, params or {})
            cols = result.get_column_names()
            rows: list[dict] = []
            while result.has_next():
                values = result.get_next()
                rows.append(dict(zip(cols, values)))
            return rows
        except Exception as exc:
            print(f"KùzuDB query failed: {exc}")
            return []

    def get_vocab_terms(self, vocab_id: str) -> list[dict]:
        """Return terms defined by a vocabulary."""
        if not self._available:
            return []
        return self.run_query(
            "MATCH (v:ODataVocabulary {vocabId: $id})-[:DEFINES_TERM]->(t:VocabularyTerm) "
            "RETURN t.termId AS termId, t.name AS name, t.type AS type, "
            "t.appliesTo AS appliesTo, t.description AS description, "
            "'defines_term' AS relation",
            {"id": vocab_id},
        )

    def get_term_usage(self, term_id: str) -> list[dict]:
        """Return annotation targets that use a given term."""
        if not self._available:
            return []
        return self.run_query(
            "MATCH (a:AnnotationTarget)-[:ANNOTATES]->(t:VocabularyTerm {termId: $id}) "
            "RETURN a.targetId AS targetId, a.entityType AS entityType, "
            "a.namespace AS namespace, a.usedInVocab AS usedInVocab, "
            "'annotates' AS relation",
            {"id": term_id},
        )


# ---------------------------------------------------------------------------
# Singleton
# ---------------------------------------------------------------------------

_instance: KuzuStore | None = None


def get_kuzu_store() -> KuzuStore:
    global _instance
    if _instance is None:
        _instance = KuzuStore(os.environ.get("KUZU_DB_PATH", ".kuzu-odata-vocab"))
    return _instance


def _reset_kuzu_store() -> None:
    global _instance
    _instance = None
