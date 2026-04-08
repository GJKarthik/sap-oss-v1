# =============================================================================
# team_resolver.py — Layered resolution engine for team-scoped configuration
#
# Merges configuration in priority order: global → domain → country → team.
# Each layer can override or extend the previous one.
# =============================================================================
from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Optional

from .team_context import GLOBAL_CONTEXT, ScopeLevel, TeamContext

logger = logging.getLogger(__name__)


@dataclass
class GlossaryEntry:
    """A glossary term with its scope provenance."""
    source_text: str
    target_text: str
    source_lang: str = "en"
    target_lang: str = "ar"
    category: str = "financial"
    pair_type: str = "translation"
    scope_level: str = "global"
    team_id: str = "global"
    is_approved: bool = True


@dataclass
class PromptConfig:
    """Resolved prompt configuration for a team × product."""
    system_prompt: str = ""
    system_prompt_append: str = ""
    temperature: float = 0.3
    max_tokens: int = 4096

    @property
    def full_prompt(self) -> str:
        if self.system_prompt_append:
            return f"{self.system_prompt}\n\n{self.system_prompt_append}"
        return self.system_prompt


@dataclass
class ProductAccess:
    """A data product with its access level for a team."""
    product_id: str
    access_level: str = "read"


@dataclass
class TrainingConfig:
    """Resolved training configuration for a team."""
    domain: str = ""
    include_patterns: list[str] = field(default_factory=list)
    exclude_patterns: list[str] = field(default_factory=list)
    custom_templates_path: str = ""
    enable_bilingual: bool = False
    country_filter: str = ""


@dataclass
class _CacheEntry:
    """Internal cache entry with TTL."""
    data: Any
    expires_at: float


class TeamResolver:
    """
    Resolves team-scoped configuration by merging layers.

    Queries HANA tables (TEAM_CONFIG, TEAM_GLOSSARY, TEAM_PRODUCT_ACCESS,
    TEAM_PROMPT_OVERRIDE, TEAM_TRAINING_CONFIG) and merges results according
    to scope_chain priority.

    Results are cached in-memory with a configurable TTL.
    """

    def __init__(self, hana_client: Any = None, cache_ttl_seconds: int = 300) -> None:
        self._hana = hana_client
        self._cache_ttl = cache_ttl_seconds
        self._cache: dict[str, _CacheEntry] = {}

    def _get_cached(self, key: str) -> Any | None:
        entry = self._cache.get(key)
        if entry and entry.expires_at > time.monotonic():
            return entry.data
        if entry:
            del self._cache[key]
        return None

    def _set_cached(self, key: str, data: Any) -> None:
        self._cache[key] = _CacheEntry(data=data, expires_at=time.monotonic() + self._cache_ttl)

    def invalidate(self, team_id: str = "") -> None:
        """Clear cache for a specific team or all entries."""
        if not team_id:
            self._cache.clear()
            return
        keys_to_remove = [k for k in self._cache if team_id in k]
        for k in keys_to_remove:
            del self._cache[k]

    # -------------------------------------------------------------------------
    # Glossary resolution
    # -------------------------------------------------------------------------

    def resolve_glossary(self, ctx: TeamContext) -> list[GlossaryEntry]:
        """
        Merge glossary entries across scope layers.

        Later scopes override earlier ones when source_text matches.
        """
        cache_key = f"glossary:{ctx.team_id}"
        cached = self._get_cached(cache_key)
        if cached is not None:
            return cached

        merged: dict[str, GlossaryEntry] = {}

        for scope_level, scope_key in ctx.scope_chain():
            entries = self._query_glossary(scope_level.value, scope_key)
            for entry in entries:
                # Key by source_text+source_lang — later scopes override
                merge_key = f"{entry.source_text.lower()}:{entry.source_lang}"
                merged[merge_key] = entry

        result = list(merged.values())
        self._set_cached(cache_key, result)
        return result

    def _query_glossary(self, scope_level: str, scope_key: str) -> list[GlossaryEntry]:
        """Query HANA TEAM_GLOSSARY for a specific scope."""
        if not self._hana:
            return []
        try:
            rows = self._hana.execute(
                'SELECT "SOURCE_TEXT", "TARGET_TEXT", "SOURCE_LANG", "TARGET_LANG", '
                '"CATEGORY", "PAIR_TYPE", "SCOPE_LEVEL", "TEAM_ID", "IS_APPROVED" '
                'FROM "FINSIGHT_CORE"."TEAM_GLOSSARY" '
                'WHERE "SCOPE_LEVEL" = ? AND "TEAM_ID" = ? AND "IS_APPROVED" = TRUE',
                (scope_level, scope_key),
            )
            return [
                GlossaryEntry(
                    source_text=r["SOURCE_TEXT"],
                    target_text=r["TARGET_TEXT"],
                    source_lang=r["SOURCE_LANG"],
                    target_lang=r["TARGET_LANG"],
                    category=r["CATEGORY"],
                    pair_type=r["PAIR_TYPE"],
                    scope_level=r["SCOPE_LEVEL"],
                    team_id=r["TEAM_ID"],
                    is_approved=r["IS_APPROVED"],
                )
                for r in rows
            ]
        except Exception:
            logger.exception("Failed to query TEAM_GLOSSARY for %s/%s", scope_level, scope_key)
            return []

    # -------------------------------------------------------------------------
    # Product access resolution
    # -------------------------------------------------------------------------

    def resolve_products(self, ctx: TeamContext) -> list[ProductAccess]:
        """Return data products accessible to this team context."""
        cache_key = f"products:{ctx.team_id}"
        cached = self._get_cached(cache_key)
        if cached is not None:
            return cached

        result: dict[str, ProductAccess] = {}

        for _, scope_key in ctx.scope_chain():
            for pa in self._query_product_access(scope_key):
                result[pa.product_id] = pa

        products = list(result.values())
        self._set_cached(cache_key, products)
        return products

    def _query_product_access(self, team_id: str) -> list[ProductAccess]:
        if not self._hana:
            return []
        try:
            rows = self._hana.execute(
                'SELECT "PRODUCT_ID", "ACCESS_LEVEL" '
                'FROM "FINSIGHT_CORE"."TEAM_PRODUCT_ACCESS" '
                'WHERE "TEAM_ID" = ?',
                (team_id,),
            )
            return [ProductAccess(product_id=r["PRODUCT_ID"], access_level=r["ACCESS_LEVEL"]) for r in rows]
        except Exception:
            logger.exception("Failed to query TEAM_PRODUCT_ACCESS for %s", team_id)
            return []

    # -------------------------------------------------------------------------
    # Prompt resolution
    # -------------------------------------------------------------------------

    def resolve_prompt(self, ctx: TeamContext, product_id: str, base_prompt: str = "") -> PromptConfig:
        """Resolve LLM prompt by merging base prompt with team overrides."""
        cache_key = f"prompt:{ctx.team_id}:{product_id}"
        cached = self._get_cached(cache_key)
        if cached is not None:
            return cached

        config = PromptConfig(system_prompt=base_prompt)
        appends: list[str] = []

        for _, scope_key in ctx.scope_chain():
            override = self._query_prompt_override(scope_key, product_id)
            if override:
                if override.get("SYSTEM_PROMPT_APPEND"):
                    appends.append(override["SYSTEM_PROMPT_APPEND"])
                if override.get("TEMPERATURE") is not None:
                    config.temperature = float(override["TEMPERATURE"])
                if override.get("MAX_TOKENS") is not None:
                    config.max_tokens = int(override["MAX_TOKENS"])

        config.system_prompt_append = "\n".join(appends)
        self._set_cached(cache_key, config)
        return config

    def _query_prompt_override(self, team_id: str, product_id: str) -> dict[str, Any] | None:
        if not self._hana:
            return None
        try:
            rows = self._hana.execute(
                'SELECT "SYSTEM_PROMPT_APPEND", "TEMPERATURE", "MAX_TOKENS" '
                'FROM "FINSIGHT_CORE"."TEAM_PROMPT_OVERRIDE" '
                'WHERE "TEAM_ID" = ? AND ("PRODUCT_ID" = ? OR "PRODUCT_ID" = \'*\') '
                'ORDER BY CASE WHEN "PRODUCT_ID" = \'*\' THEN 0 ELSE 1 END',
                (team_id, product_id),
            )
            return rows[0] if rows else None
        except Exception:
            logger.exception("Failed to query TEAM_PROMPT_OVERRIDE for %s/%s", team_id, product_id)
            return None

    # -------------------------------------------------------------------------
    # Training config resolution
    # -------------------------------------------------------------------------

    def resolve_training_config(self, ctx: TeamContext) -> TrainingConfig:
        """Resolve training configuration for a team context."""
        cache_key = f"training:{ctx.team_id}"
        cached = self._get_cached(cache_key)
        if cached is not None:
            return cached

        config = TrainingConfig(
            domain=ctx.domain,
            enable_bilingual=ctx.has_arabic_locale,
            country_filter=ctx.country_filter_value if ctx.country else "",
        )

        if self._hana:
            try:
                rows = self._hana.execute(
                    'SELECT "DOMAIN", "INCLUDE_PATTERNS", "EXCLUDE_PATTERNS", '
                    '"CUSTOM_TEMPLATES_PATH", "ENABLE_BILINGUAL", "COUNTRY_FILTER" '
                    'FROM "FINSIGHT_CORE"."TEAM_TRAINING_CONFIG" '
                    'WHERE "TEAM_ID" = ?',
                    (ctx.team_id,),
                )
                if rows:
                    r = rows[0]
                    config.domain = r.get("DOMAIN") or config.domain
                    config.custom_templates_path = r.get("CUSTOM_TEMPLATES_PATH") or ""
                    config.enable_bilingual = r.get("ENABLE_BILINGUAL", config.enable_bilingual)
                    config.country_filter = r.get("COUNTRY_FILTER") or config.country_filter
                    if r.get("INCLUDE_PATTERNS"):
                        config.include_patterns = json.loads(r["INCLUDE_PATTERNS"])
                    if r.get("EXCLUDE_PATTERNS"):
                        config.exclude_patterns = json.loads(r["EXCLUDE_PATTERNS"])
            except Exception:
                logger.exception("Failed to query TEAM_TRAINING_CONFIG for %s", ctx.team_id)

        self._set_cached(cache_key, config)
        return config
