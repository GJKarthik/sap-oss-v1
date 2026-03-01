"""
Unit Tests for Configuration Management

Day 5 Deliverable: Comprehensive tests for config/settings.py
Target: >80% code coverage
"""

import pytest
import os
from unittest.mock import patch, MagicMock

from mangle_query_service.config.settings import (
    Environment,
    ServerConfig,
    ElasticsearchConfig,
    HANAConfig,
    LLMBackendConfig,
    AICoreSteamingConfig,
    CacheConfig,
    ResilienceConfig,
    SecurityConfig,
    ObservabilityConfig,
    Settings,
    get_settings,
    reset_settings,
    load_settings_from_env,
    get_development_settings,
    get_staging_settings,
    get_production_settings,
    _get_env,
)


# ========================================
# Fixtures
# ========================================

@pytest.fixture(autouse=True)
def reset_settings_before_each():
    """Reset settings singleton before each test."""
    reset_settings()
    yield
    reset_settings()


@pytest.fixture
def clean_env():
    """Clean environment variables for testing."""
    env_vars = [
        "MANGLE_ENV", "DEBUG", "SERVER_PORT",
        "ELASTICSEARCH_URL", "ELASTICSEARCH_USERNAME",
        "HANA_HOST", "HANA_USER", "HANA_PASSWORD",
        "LLM_API_KEY", "API_KEYS", "JWT_SECRET",
    ]
    original = {k: os.environ.get(k) for k in env_vars}
    for k in env_vars:
        if k in os.environ:
            del os.environ[k]
    yield
    for k, v in original.items():
        if v is not None:
            os.environ[k] = v
        elif k in os.environ:
            del os.environ[k]


# ========================================
# Environment Tests
# ========================================

class TestEnvironment:
    """Tests for Environment enum."""
    
    def test_environment_values(self):
        """Test environment enum values."""
        assert Environment.DEVELOPMENT.value == "development"
        assert Environment.STAGING.value == "staging"
        assert Environment.PRODUCTION.value == "production"
        assert Environment.TEST.value == "test"
    
    def test_environment_from_string(self):
        """Test creating environment from string."""
        assert Environment("development") == Environment.DEVELOPMENT
        assert Environment("production") == Environment.PRODUCTION


# ========================================
# ServerConfig Tests
# ========================================

class TestServerConfig:
    """Tests for ServerConfig."""
    
    def test_default_values(self):
        """Test default server configuration."""
        config = ServerConfig()
        
        assert config.host == "0.0.0.0"
        assert config.port == 8080
        assert config.workers == 4
        assert config.debug is False
        assert config.log_level == "INFO"
        assert "*" in config.cors_origins
    
    def test_custom_values(self):
        """Test custom server configuration."""
        config = ServerConfig(
            host="127.0.0.1",
            port=3000,
            workers=8,
            debug=True,
        )
        
        assert config.host == "127.0.0.1"
        assert config.port == 3000
        assert config.workers == 8
        assert config.debug is True


# ========================================
# ElasticsearchConfig Tests
# ========================================

class TestElasticsearchConfig:
    """Tests for ElasticsearchConfig."""
    
    def test_default_values(self):
        """Test default Elasticsearch configuration."""
        config = ElasticsearchConfig()
        
        assert config.url == "http://localhost:9200"
        assert config.index_prefix == "mangle"
        assert config.username is None
        assert config.has_auth is False
    
    def test_has_auth_with_username(self):
        """Test has_auth with username."""
        config = ElasticsearchConfig(username="elastic")
        
        assert config.has_auth is True
    
    def test_has_auth_with_api_key(self):
        """Test has_auth with API key."""
        config = ElasticsearchConfig(api_key="secret-key")
        
        assert config.has_auth is True


# ========================================
# HANAConfig Tests
# ========================================

class TestHANAConfig:
    """Tests for HANAConfig."""
    
    def test_default_not_configured(self):
        """Test default HANA is not configured."""
        config = HANAConfig()
        
        assert config.is_configured is False
        assert config.connection_string == ""
    
    def test_is_configured(self):
        """Test is_configured with credentials."""
        config = HANAConfig(
            host="hana.example.com",
            user="admin",
            password="secret",
            schema="MYSCHEMA",
        )
        
        assert config.is_configured is True
        assert "hana.example.com" in config.connection_string
        assert "admin" in config.connection_string
        assert "secret" not in config.connection_string  # Password not in string


# ========================================
# LLMBackendConfig Tests
# ========================================

class TestLLMBackendConfig:
    """Tests for LLMBackendConfig."""
    
    def test_default_values(self):
        """Test default LLM configuration."""
        config = LLMBackendConfig()
        
        assert config.base_url == "http://localhost:8000/v1"
        assert config.model == "gpt-4"
        assert config.timeout == 120.0
    
    def test_custom_model(self):
        """Test custom model configuration."""
        config = LLMBackendConfig(model="claude-3-opus")
        
        assert config.model == "claude-3-opus"


# ========================================
# AICoreSteamingConfig Tests
# ========================================

class TestAICoreSteamingConfig:
    """Tests for AICoreSteamingConfig."""
    
    def test_default_not_configured(self):
        """Test default AI Core is not configured."""
        config = AICoreSteamingConfig()
        
        assert config.is_configured is False
    
    def test_is_configured(self):
        """Test is_configured with credentials."""
        config = AICoreSteamingConfig(
            base_url="https://api.ai.cloud.sap",
            client_id="client-123",
            client_secret="secret-456",
        )
        
        assert config.is_configured is True


# ========================================
# Settings Tests
# ========================================

class TestSettings:
    """Tests for Settings class."""
    
    def test_default_settings(self):
        """Test default settings."""
        settings = Settings()
        
        assert settings.environment == Environment.DEVELOPMENT
        assert settings.service_name == "mangle-query-service"
        assert settings.is_development is True
        assert settings.is_production is False
    
    def test_production_settings(self):
        """Test production detection."""
        settings = Settings(environment=Environment.PRODUCTION)
        
        assert settings.is_production is True
        assert settings.is_development is False
    
    def test_to_dict_masks_secrets(self):
        """Test to_dict masks secrets."""
        settings = Settings(
            aicore=AICoreSteamingConfig(
                base_url="https://api.ai.cloud.sap",
            )
        )
        
        result = settings.to_dict(mask_secrets=True)
        
        assert result["aicore"]["base_url"] == "***"
    
    def test_to_dict_shows_secrets(self):
        """Test to_dict can show secrets."""
        settings = Settings(
            aicore=AICoreSteamingConfig(
                base_url="https://api.ai.cloud.sap",
            )
        )
        
        result = settings.to_dict(mask_secrets=False)
        
        assert result["aicore"]["base_url"] == "https://api.ai.cloud.sap"


# ========================================
# Validation Tests
# ========================================

class TestValidation:
    """Tests for settings validation."""
    
    def test_valid_development(self):
        """Test valid development settings."""
        settings = get_development_settings()
        errors = settings.validate()
        
        # Development allows debug and wildcard CORS
        assert not errors
    
    def test_production_debug_error(self):
        """Test production rejects debug mode."""
        settings = Settings(
            environment=Environment.PRODUCTION,
            server=ServerConfig(debug=True),
        )
        
        errors = settings.validate()
        
        assert any("Debug mode" in e for e in errors)
    
    def test_production_wildcard_cors_error(self):
        """Test production rejects wildcard CORS."""
        settings = Settings(
            environment=Environment.PRODUCTION,
            server=ServerConfig(cors_origins=["*"]),
        )
        
        errors = settings.validate()
        
        assert any("Wildcard CORS" in e for e in errors)
    
    def test_production_requires_auth(self):
        """Test production requires authentication."""
        settings = Settings(
            environment=Environment.PRODUCTION,
            server=ServerConfig(
                debug=False,
                cors_origins=["https://example.com"],
            ),
            elasticsearch=ElasticsearchConfig(username="elastic"),
        )
        
        errors = settings.validate()
        
        assert any("authentication required" in e for e in errors)
    
    def test_invalid_port(self):
        """Test invalid port detection."""
        settings = Settings(
            server=ServerConfig(port=99999),
        )
        
        errors = settings.validate()
        
        assert any("Invalid server port" in e for e in errors)
    
    def test_invalid_similarity_threshold(self):
        """Test invalid similarity threshold."""
        settings = Settings(
            cache=CacheConfig(similarity_threshold=1.5),
        )
        
        errors = settings.validate()
        
        assert any("similarity_threshold" in e for e in errors)


# ========================================
# Environment Variable Loading Tests
# ========================================

class TestEnvLoading:
    """Tests for environment variable loading."""
    
    def test_get_env_string(self, clean_env):
        """Test _get_env with string."""
        os.environ["TEST_VAR"] = "hello"
        
        result = _get_env("TEST_VAR", "default")
        
        assert result == "hello"
        del os.environ["TEST_VAR"]
    
    def test_get_env_default(self, clean_env):
        """Test _get_env with default."""
        result = _get_env("NONEXISTENT_VAR", "default")
        
        assert result == "default"
    
    def test_get_env_int(self, clean_env):
        """Test _get_env with int cast."""
        os.environ["TEST_INT"] = "42"
        
        result = _get_env("TEST_INT", 0, int)
        
        assert result == 42
        assert isinstance(result, int)
        del os.environ["TEST_INT"]
    
    def test_get_env_bool_true(self, clean_env):
        """Test _get_env with bool true."""
        for true_val in ["true", "1", "yes", "on"]:
            os.environ["TEST_BOOL"] = true_val
            
            result = _get_env("TEST_BOOL", False, bool)
            
            assert result is True
            del os.environ["TEST_BOOL"]
    
    def test_get_env_bool_false(self, clean_env):
        """Test _get_env with bool false."""
        os.environ["TEST_BOOL"] = "false"
        
        result = _get_env("TEST_BOOL", True, bool)
        
        assert result is False
        del os.environ["TEST_BOOL"]
    
    def test_get_env_list(self, clean_env):
        """Test _get_env with list."""
        os.environ["TEST_LIST"] = "a,b,c"
        
        result = _get_env("TEST_LIST", [], list)
        
        assert result == ["a", "b", "c"]
        del os.environ["TEST_LIST"]
    
    def test_get_env_set(self, clean_env):
        """Test _get_env with set."""
        os.environ["TEST_SET"] = "x,y,z"
        
        result = _get_env("TEST_SET", set(), set)
        
        assert result == {"x", "y", "z"}
        del os.environ["TEST_SET"]
    
    def test_load_settings_from_env(self, clean_env):
        """Test loading settings from environment."""
        os.environ["MANGLE_ENV"] = "staging"
        os.environ["SERVER_PORT"] = "3000"
        os.environ["DEBUG"] = "true"
        
        settings = load_settings_from_env()
        
        assert settings.environment == Environment.STAGING
        assert settings.server.port == 3000
        assert settings.server.debug is True
        
        del os.environ["MANGLE_ENV"]
        del os.environ["SERVER_PORT"]
        del os.environ["DEBUG"]


# ========================================
# Preset Tests
# ========================================

class TestPresets:
    """Tests for environment presets."""
    
    def test_development_preset(self):
        """Test development preset."""
        settings = get_development_settings()
        
        assert settings.environment == Environment.DEVELOPMENT
        assert settings.server.debug is True
        assert settings.server.workers == 1
        assert settings.cache.enabled is False
        assert settings.resilience.circuit_breaker_enabled is False
    
    def test_staging_preset(self):
        """Test staging preset."""
        settings = get_staging_settings()
        
        assert settings.environment == Environment.STAGING
        assert settings.server.debug is False
        assert settings.server.workers == 2
        assert settings.cache.enabled is True
        assert settings.observability.tracing_enabled is True
    
    def test_production_preset(self):
        """Test production preset."""
        settings = get_production_settings()
        
        assert settings.environment == Environment.PRODUCTION
        assert settings.server.debug is False
        assert settings.server.workers == 4
        assert settings.cache.enabled is True
        assert settings.cache.max_entries == 50000
        assert settings.security.rate_limit_enabled is True


# ========================================
# Singleton Tests
# ========================================

class TestSingleton:
    """Tests for settings singleton."""
    
    def test_get_settings_singleton(self, clean_env):
        """Test get_settings returns singleton."""
        settings1 = get_settings()
        settings2 = get_settings()
        
        assert settings1 is settings2
    
    def test_get_settings_reload(self, clean_env):
        """Test get_settings reload."""
        settings1 = get_settings()
        settings2 = get_settings(reload=True)
        
        # Different instance after reload
        assert settings1 is not settings2
    
    def test_reset_settings(self, clean_env):
        """Test reset_settings."""
        settings1 = get_settings()
        reset_settings()
        settings2 = get_settings()
        
        assert settings1 is not settings2


# ========================================
# Run Tests
# ========================================

if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])