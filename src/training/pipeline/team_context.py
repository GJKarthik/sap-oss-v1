# =============================================================================
# team_context.py — Team Context model for Country × Domain scoping
# =============================================================================
from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from enum import Enum
from typing import Any, Optional

logger = logging.getLogger(__name__)


class ScopeLevel(str, Enum):
    """Hierarchy of configuration scopes — later overrides earlier."""
    GLOBAL = "global"
    DOMAIN = "domain"
    COUNTRY = "country"
    TEAM = "team"

    @property
    def priority(self) -> int:
        return {"global": 0, "domain": 1, "country": 2, "team": 3}[self.value]


SUPPORTED_COUNTRIES = frozenset({"CN", "HK", "IN", "SG", "TW", "AE", "GB", "US"})
SUPPORTED_DOMAINS = frozenset({"treasury", "esg", "performance"})

COUNTRY_DISPLAY_NAMES: dict[str, str] = {
    "CN": "China", "HK": "Hong Kong", "IN": "India", "SG": "Singapore",
    "TW": "Taiwan", "AE": "United Arab Emirates", "GB": "United Kingdom",
    "US": "United States of America",
}

COUNTRY_FILTER_VALUES: dict[str, str] = {
    "CN": "CHINA", "HK": "HONG KONG", "IN": "INDIA", "SG": "SINGAPORE",
    "TW": "TAIWAN", "AE": "UNITED ARAB EMIRATES", "GB": "UNITED KINGDOM",
    "US": "UNITED STATES OF AMERICA",
}

ARABIC_LOCALE_COUNTRIES = frozenset({"AE"})


@dataclass(frozen=True)
class TeamContext:
    """Immutable Country × Domain team context that flows through the stack."""
    country: str = ""
    domain: str = ""

    @property
    def team_id(self) -> str:
        if self.country and self.domain:
            return f"{self.country}:{self.domain}"
        return self.country or self.domain or "global"

    @property
    def is_global(self) -> bool:
        return not self.country and not self.domain

    @property
    def scope_level(self) -> ScopeLevel:
        if self.country and self.domain:
            return ScopeLevel.TEAM
        if self.country:
            return ScopeLevel.COUNTRY
        if self.domain:
            return ScopeLevel.DOMAIN
        return ScopeLevel.GLOBAL

    @property
    def has_arabic_locale(self) -> bool:
        return self.country in ARABIC_LOCALE_COUNTRIES

    @property
    def country_display_name(self) -> str:
        return COUNTRY_DISPLAY_NAMES.get(self.country, self.country)

    @property
    def country_filter_value(self) -> str:
        return COUNTRY_FILTER_VALUES.get(self.country, self.country.upper())

    def scope_chain(self) -> list[tuple[ScopeLevel, str]]:
        """Ordered scope keys from broadest to most specific for merge."""
        chain: list[tuple[ScopeLevel, str]] = [(ScopeLevel.GLOBAL, "global")]
        if self.domain:
            chain.append((ScopeLevel.DOMAIN, self.domain))
        if self.country:
            chain.append((ScopeLevel.COUNTRY, self.country))
        if self.country and self.domain:
            chain.append((ScopeLevel.TEAM, self.team_id))
        return chain

    def to_dict(self) -> dict[str, str]:
        return {"country": self.country, "domain": self.domain, "team_id": self.team_id}

    def to_header_value(self) -> str:
        return json.dumps({"country": self.country, "domain": self.domain})

    # --- Factory methods ---

    @classmethod
    def from_header(cls, header_value: str) -> TeamContext:
        """Parse from X-Team-Context HTTP header (JSON string)."""
        try:
            data = json.loads(header_value)
            return cls(
                country=str(data.get("country", "")).upper().strip(),
                domain=str(data.get("domain", "")).lower().strip(),
            )
        except (json.JSONDecodeError, AttributeError):
            logger.warning("Invalid X-Team-Context header: %s", header_value)
            return cls()

    @classmethod
    def from_jwt_claims(cls, claims: dict[str, Any]) -> TeamContext:
        """Extract team context from JWT token claims."""
        return cls(
            country=str(claims.get("country_code", "")).upper().strip(),
            domain=str(claims.get("business_domain", "")).lower().strip(),
        )

    @classmethod
    def from_cli(cls, team_arg: str) -> TeamContext:
        """Parse from CLI --team flag (e.g. 'AE:treasury' or 'treasury')."""
        if not team_arg:
            return cls()
        parts = team_arg.split(":", 1)
        if len(parts) == 2:
            return cls(country=parts[0].upper().strip(), domain=parts[1].lower().strip())
        val = parts[0].strip()
        if val.upper() in SUPPORTED_COUNTRIES:
            return cls(country=val.upper())
        if val.lower() in SUPPORTED_DOMAINS:
            return cls(domain=val.lower())
        logger.warning("Unrecognized team arg '%s', treating as domain", val)
        return cls(domain=val.lower())


# Sentinel for global/admin context
GLOBAL_CONTEXT = TeamContext()
