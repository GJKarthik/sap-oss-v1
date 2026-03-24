"""
Persistent store seeding: populates default records on startup.
"""

import bcrypt
import structlog
from dataclasses import asdict

from .config import settings
from .models import AIModel, GovernanceRule, User
from .store import get_store

logger = structlog.get_logger()
_DEMO_ENVIRONMENTS = {"development", "dev", "local", "test"}


def _hash_password(plain: str) -> str:
    return bcrypt.hashpw(plain.encode(), bcrypt.gensalt()).decode()


def seed_store() -> None:
    """Idempotently seed default records into the configured persistent store."""
    store = get_store()
    _seed_admin_user(store)
    if settings.seed_reference_data:
        _seed_ai_models(store)
        _seed_governance_rules(store)
    else:
        logger.info(
            "Skipping reference data seeding outside development/test",
            environment=settings.environment,
        )
    logger.info("Persistent store seeding completed")


def _seed_admin_user(store) -> None:
    environment = settings.environment.lower()

    if environment in _DEMO_ENVIRONMENTS:
        _seed_specific_admin_user(
            store,
            username="admin",
            password="changeme",
            email="admin@sap-ai-fabric.local",
            log_message="Seeded default admin user for local/demo use",
        )
        return

    username = settings.bootstrap_admin_username.strip()
    password = settings.bootstrap_admin_password
    email = settings.bootstrap_admin_email

    if not username or not password:
        logger.info(
            "Skipping admin user seeding outside development/test",
            environment=settings.environment,
        )
        return

    _seed_specific_admin_user(
        store,
        username=username,
        password=password,
        email=email,
        log_message="Seeded bootstrap admin user from configuration",
    )


def _seed_specific_admin_user(
    store,
    *,
    username: str,
    password: str,
    email: str,
    log_message: str,
) -> None:
    if store.has_record("users", username):
        return

    admin = User(
        username=username,
        email=email,
        hashed_password=_hash_password(password),
        role="admin",
    )
    store.set_record("users", username, asdict(admin))
    logger.info(log_message, username=username)


def _seed_ai_models(store) -> None:
    defaults = [
        AIModel(
            id="mistral-7b",
            name="Mistral 7B",
            provider="sap-ai-core",
            version="0.3",
            description="Open-weight 7B parameter model",
            context_window=8192,
            capabilities=["chat", "completion"],
        ),
        AIModel(
            id="claude-3.7-sonnet",
            name="Claude 3.7 Sonnet",
            provider="sap-ai-core",
            version="1.0",
            description="Anthropic Claude 3.7 Sonnet via SAP AI Core",
            context_window=200000,
            capabilities=["chat", "completion", "vision"],
        ),
        AIModel(
            id="gpt-4o",
            name="GPT-4o",
            provider="sap-ai-core",
            version="1.0",
            description="OpenAI GPT-4o deployment via SAP AI Core",
            context_window=128000,
            capabilities=["chat", "completion", "vision"],
        ),
    ]
    for model in defaults:
        if not store.has_record("models", model.id):
            store.set_record("models", model.id, asdict(model))
            logger.info("Seeded AI model", model_id=model.id)


def _seed_governance_rules(store) -> None:
    defaults = [
        GovernanceRule(
            id="rule-001",
            name="PII Detection",
            rule_type="content-filter",
            active=True,
            description="Detect and redact PII in prompts and responses",
        ),
        GovernanceRule(
            id="rule-002",
            name="Rate Limiting",
            rule_type="access-control",
            active=True,
            description="Enforce per-user rate limits",
        ),
        GovernanceRule(
            id="rule-003",
            name="Audit Logging",
            rule_type="compliance",
            active=True,
            description="Log all AI interactions for compliance",
        ),
    ]
    for rule in defaults:
        if not store.has_record("governance_rules", rule.id):
            store.set_record("governance_rules", rule.id, asdict(rule))
            logger.info("Seeded governance rule", rule_id=rule.id)
