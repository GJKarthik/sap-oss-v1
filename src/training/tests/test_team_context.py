#!/usr/bin/env python3
"""Tests for TeamContext dataclass and TeamResolver service."""

import json
import time
import pytest
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent.parent))
from pipeline.team_context import (
    TeamContext,
    ScopeLevel,
    GLOBAL_CONTEXT,
    SUPPORTED_COUNTRIES,
    SUPPORTED_DOMAINS,
    COUNTRY_FILTER_VALUES,
)
from pipeline.team_resolver import (
    TeamResolver,
    GlossaryEntry,
    PromptConfig,
    ProductAccess,
    TrainingConfig,
)


# =============================================================================
# TeamContext tests
# =============================================================================

class TestTeamContext:
    """Tests for the TeamContext dataclass."""

    def test_global_context(self):
        ctx = TeamContext()
        assert ctx.is_global
        assert ctx.team_id == "global"
        assert ctx.scope_level == ScopeLevel.GLOBAL

    def test_country_only(self):
        ctx = TeamContext(country="AE")
        assert not ctx.is_global
        assert ctx.team_id == "AE"
        assert ctx.scope_level == ScopeLevel.COUNTRY
        assert ctx.country_display_name == "United Arab Emirates"
        assert ctx.country_filter_value == "UNITED ARAB EMIRATES"

    def test_domain_only(self):
        ctx = TeamContext(domain="treasury")
        assert not ctx.is_global
        assert ctx.team_id == "treasury"
        assert ctx.scope_level == ScopeLevel.DOMAIN

    def test_full_team(self):
        ctx = TeamContext(country="AE", domain="treasury")
        assert ctx.team_id == "AE:treasury"
        assert ctx.scope_level == ScopeLevel.TEAM
        assert not ctx.is_global

    def test_arabic_locale(self):
        assert TeamContext(country="AE").has_arabic_locale
        assert not TeamContext(country="GB").has_arabic_locale
        assert not TeamContext().has_arabic_locale

    def test_scope_chain_global(self):
        chain = GLOBAL_CONTEXT.scope_chain()
        assert len(chain) == 1
        assert chain[0] == (ScopeLevel.GLOBAL, "global")

    def test_scope_chain_team(self):
        ctx = TeamContext(country="AE", domain="treasury")
        chain = ctx.scope_chain()
        assert len(chain) == 4
        assert chain[0] == (ScopeLevel.GLOBAL, "global")
        assert chain[1] == (ScopeLevel.DOMAIN, "treasury")
        assert chain[2] == (ScopeLevel.COUNTRY, "AE")
        assert chain[3] == (ScopeLevel.TEAM, "AE:treasury")

    def test_scope_chain_domain_only(self):
        ctx = TeamContext(domain="esg")
        chain = ctx.scope_chain()
        assert len(chain) == 2
        assert chain[1] == (ScopeLevel.DOMAIN, "esg")

    def test_scope_chain_country_only(self):
        ctx = TeamContext(country="SG")
        chain = ctx.scope_chain()
        assert len(chain) == 2
        assert chain[1] == (ScopeLevel.COUNTRY, "SG")

    def test_to_dict(self):
        ctx = TeamContext(country="GB", domain="esg")
        d = ctx.to_dict()
        assert d["country"] == "GB"
        assert d["domain"] == "esg"
        assert d["team_id"] == "GB:esg"

    def test_to_header_value(self):
        ctx = TeamContext(country="AE", domain="treasury")
        header = ctx.to_header_value()
        parsed = json.loads(header)
        assert parsed["country"] == "AE"
        assert parsed["domain"] == "treasury"

    def test_frozen(self):
        ctx = TeamContext(country="AE")
        with pytest.raises(AttributeError):
            ctx.country = "GB"


class TestTeamContextFactories:
    """Tests for TeamContext factory methods."""

    def test_from_header_full(self):
        header = json.dumps({"country": "ae", "domain": "Treasury"})
        ctx = TeamContext.from_header(header)
        assert ctx.country == "AE"
        assert ctx.domain == "treasury"

    def test_from_header_empty(self):
        ctx = TeamContext.from_header("{}")
        assert ctx.is_global

    def test_from_header_invalid(self):
        ctx = TeamContext.from_header("not-json")
        assert ctx.is_global

    def test_from_jwt_claims(self):
        claims = {"country_code": "SG", "business_domain": "performance"}
        ctx = TeamContext.from_jwt_claims(claims)
        assert ctx.country == "SG"
        assert ctx.domain == "performance"

    def test_from_cli_team(self):
        ctx = TeamContext.from_cli("AE:treasury")
        assert ctx.country == "AE"
        assert ctx.domain == "treasury"

    def test_from_cli_country(self):
        ctx = TeamContext.from_cli("GB")
        assert ctx.country == "GB"
        assert ctx.domain == ""

    def test_from_cli_domain(self):
        ctx = TeamContext.from_cli("esg")
        assert ctx.country == ""
        assert ctx.domain == "esg"

    def test_from_cli_empty(self):
        ctx = TeamContext.from_cli("")
        assert ctx.is_global


class TestScopeLevel:
    """Tests for ScopeLevel enum."""

    def test_priorities(self):
        assert ScopeLevel.GLOBAL.priority < ScopeLevel.DOMAIN.priority
        assert ScopeLevel.DOMAIN.priority < ScopeLevel.COUNTRY.priority
        assert ScopeLevel.COUNTRY.priority < ScopeLevel.TEAM.priority

    def test_string_values(self):
        assert ScopeLevel.GLOBAL.value == "global"
        assert ScopeLevel.TEAM.value == "team"


# =============================================================================
# TeamResolver tests
# =============================================================================

def _mock_hana():
    """Create a mock HanaClient."""
    return MagicMock()


class TestTeamResolverCache:
    """Tests for TeamResolver caching."""

    def test_cache_hit(self):
        hana = _mock_hana()
        hana.execute.return_value = []
        resolver = TeamResolver(hana_client=hana, cache_ttl_seconds=60)
        ctx = TeamContext(country="AE", domain="treasury")

        resolver.resolve_glossary(ctx)
        resolver.resolve_glossary(ctx)

        # HANA should only be called for the first request (4 scopes)
        first_call_count = hana.execute.call_count
        resolver.resolve_glossary(ctx)
        assert hana.execute.call_count == first_call_count

    def test_cache_expiry(self):
        hana = _mock_hana()
        hana.execute.return_value = []
        resolver = TeamResolver(hana_client=hana, cache_ttl_seconds=0)

        ctx = TeamContext(domain="esg")
        resolver.resolve_glossary(ctx)
        calls_after_first = hana.execute.call_count
        resolver.resolve_glossary(ctx)
        assert hana.execute.call_count > calls_after_first

    def test_invalidate_specific(self):
        hana = _mock_hana()
        hana.execute.return_value = []
        resolver = TeamResolver(hana_client=hana, cache_ttl_seconds=300)

        ctx = TeamContext(country="AE", domain="treasury")
        resolver.resolve_glossary(ctx)
        assert len(resolver._cache) > 0

        resolver.invalidate("AE:treasury")
        assert len(resolver._cache) == 0

    def test_invalidate_all(self):
        hana = _mock_hana()
        hana.execute.return_value = []
        resolver = TeamResolver(hana_client=hana, cache_ttl_seconds=300)

        resolver.resolve_glossary(TeamContext(country="AE"))
        resolver.resolve_glossary(TeamContext(country="GB"))
        assert len(resolver._cache) > 0

        resolver.invalidate()
        assert len(resolver._cache) == 0


class TestTeamResolverGlossary:
    """Tests for glossary resolution."""

    def test_merge_override(self):
        """Later scopes should override earlier ones for same source_text."""
        hana = _mock_hana()

        def mock_execute(sql, params):
            scope_level, scope_key = params
            if scope_level == "global":
                return [{
                    "SOURCE_TEXT": "revenue", "TARGET_TEXT": "إيرادات",
                    "SOURCE_LANG": "en", "TARGET_LANG": "ar",
                    "CATEGORY": "financial", "PAIR_TYPE": "translation",
                    "SCOPE_LEVEL": "global", "TEAM_ID": "global",
                    "IS_APPROVED": True,
                }]
            elif scope_level == "country" and scope_key == "AE":
                return [{
                    "SOURCE_TEXT": "revenue", "TARGET_TEXT": "دخل العمولات",
                    "SOURCE_LANG": "en", "TARGET_LANG": "ar",
                    "CATEGORY": "financial", "PAIR_TYPE": "translation",
                    "SCOPE_LEVEL": "country", "TEAM_ID": "AE",
                    "IS_APPROVED": True,
                }]
            return []

        hana.execute.side_effect = mock_execute
        resolver = TeamResolver(hana_client=hana)

        ctx = TeamContext(country="AE", domain="treasury")
        entries = resolver.resolve_glossary(ctx)

        revenue_entries = [e for e in entries if e.source_text == "revenue"]
        assert len(revenue_entries) == 1
        assert revenue_entries[0].target_text == "دخل العمولات"
        assert revenue_entries[0].scope_level == "country"

    def test_no_hana_returns_empty(self):
        resolver = TeamResolver(hana_client=None)
        entries = resolver.resolve_glossary(TeamContext(country="AE"))
        assert entries == []


class TestTeamResolverPrompt:
    """Tests for prompt resolution."""

    def test_prompt_merge(self):
        hana = _mock_hana()

        def mock_execute(sql, params):
            team_id, product_id = params
            if team_id == "global":
                return [{"SYSTEM_PROMPT_APPEND": "Use formal language.", "TEMPERATURE": 0.3, "MAX_TOKENS": 4096}]
            elif team_id == "AE":
                return [{"SYSTEM_PROMPT_APPEND": "Support bilingual Arabic/English.", "TEMPERATURE": 0.2, "MAX_TOKENS": None}]
            return []

        hana.execute.side_effect = mock_execute
        resolver = TeamResolver(hana_client=hana)

        ctx = TeamContext(country="AE", domain="treasury")
        config = resolver.resolve_prompt(ctx, "treasury-capital-markets-v1", base_prompt="Base prompt.")

        assert config.system_prompt == "Base prompt."
        assert "Use formal language." in config.system_prompt_append
        assert "Support bilingual Arabic/English." in config.system_prompt_append
        assert config.temperature == 0.2

    def test_prompt_no_override(self):
        resolver = TeamResolver(hana_client=None)
        config = resolver.resolve_prompt(GLOBAL_CONTEXT, "test-product", base_prompt="Hello")
        assert config.system_prompt == "Hello"
        assert config.system_prompt_append == ""


class TestTeamResolverProducts:
    """Tests for product access resolution."""

    def test_product_merge(self):
        hana = _mock_hana()

        def mock_execute(sql, params):
            (team_id,) = params
            if team_id == "global":
                return [
                    {"PRODUCT_ID": "treasury-v1", "ACCESS_LEVEL": "read"},
                    {"PRODUCT_ID": "esg-v1", "ACCESS_LEVEL": "read"},
                ]
            elif team_id == "treasury":
                return [{"PRODUCT_ID": "treasury-v1", "ACCESS_LEVEL": "write"}]
            return []

        hana.execute.side_effect = mock_execute
        resolver = TeamResolver(hana_client=hana)

        ctx = TeamContext(domain="treasury")
        products = resolver.resolve_products(ctx)
        treasury = [p for p in products if p.product_id == "treasury-v1"]
        assert len(treasury) == 1
        assert treasury[0].access_level == "write"


class TestTeamResolverTraining:
    """Tests for training config resolution."""

    def test_defaults_from_context(self):
        resolver = TeamResolver(hana_client=None)
        ctx = TeamContext(country="AE", domain="treasury")
        config = resolver.resolve_training_config(ctx)
        assert config.domain == "treasury"
        assert config.enable_bilingual is True
        assert config.country_filter == "UNITED ARAB EMIRATES"

    def test_defaults_global(self):
        resolver = TeamResolver(hana_client=None)
        config = resolver.resolve_training_config(GLOBAL_CONTEXT)
        assert config.domain == ""
        assert config.enable_bilingual is False
        assert config.country_filter == ""

    def test_hana_override(self):
        hana = _mock_hana()
        hana.execute.return_value = [{
            "DOMAIN": "treasury",
            "INCLUDE_PATTERNS": '["bond", "issuance"]',
            "EXCLUDE_PATTERNS": '[]',
            "CUSTOM_TEMPLATES_PATH": "/custom/templates",
            "ENABLE_BILINGUAL": True,
            "COUNTRY_FILTER": "UNITED ARAB EMIRATES",
        }]
        resolver = TeamResolver(hana_client=hana)
        ctx = TeamContext(country="AE", domain="treasury")
        config = resolver.resolve_training_config(ctx)
        assert config.include_patterns == ["bond", "issuance"]
        assert config.custom_templates_path == "/custom/templates"
