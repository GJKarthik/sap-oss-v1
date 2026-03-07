"""
Unit Tests for Configuration Settings

Tests the centralized configuration management.
"""

import pytest
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from config.settings import (
    Settings, HANAConfig, ElasticsearchConfig, OpenAIConfig,
    AuthConfig, AuditConfig, ServerConfig, get_settings, reload_settings
)


class TestHANAConfig:
    """Tests for HANA configuration"""
    
    def test_default_values(self):
        """Test default HANA configuration values"""
        config = HANAConfig()
        assert config.host == ""
        assert config.port == 443
        assert config.encrypt == True
        assert config.connection_timeout == 30
    
    def test_is_configured_false_when_empty(self):
        """Test is_configured returns False when credentials missing"""
        config = HANAConfig()
        assert config.is_configured() == False
    
    def test_is_configured_true_with_credentials(self):
        """Test is_configured returns True with valid credentials"""
        config = HANAConfig(
            host="test.hana.cloud.sap",
            user="admin",
            password="secret"
        )
        assert config.is_configured() == True
    
    def test_from_env(self, monkeypatch):
        """Test loading config from environment variables"""
        monkeypatch.setenv("HANA_HOST", "env-host.hana.cloud.sap")
        monkeypatch.setenv("HANA_PORT", "30015")
        monkeypatch.setenv("HANA_USER", "env_user")
        monkeypatch.setenv("HANA_PASSWORD", "env_password")
        
        config = HANAConfig.from_env()
        
        assert config.host == "env-host.hana.cloud.sap"
        assert config.port == 30015
        assert config.user == "env_user"
        assert config.password == "env_password"


class TestElasticsearchConfig:
    """Tests for Elasticsearch configuration"""
    
    def test_default_values(self):
        """Test default ES configuration values"""
        config = ElasticsearchConfig()
        assert config.hosts == ["http://localhost:9200"]
        assert config.index_prefix == "odata"
        assert config.verify_certs == True
    
    def test_is_configured_with_api_key(self):
        """Test is_configured with API key"""
        config = ElasticsearchConfig(api_key="test-api-key")
        assert config.is_configured() == True
    
    def test_is_configured_with_username_password(self):
        """Test is_configured with username/password"""
        config = ElasticsearchConfig(username="elastic", password="secret")
        assert config.is_configured() == True
    
    def test_is_configured_with_cloud_id(self):
        """Test is_configured with cloud ID"""
        config = ElasticsearchConfig(cloud_id="my-deployment:dXMt...")
        assert config.is_configured() == True
    
    def test_from_env(self, monkeypatch):
        """Test loading from environment"""
        monkeypatch.setenv("ES_HOSTS", "http://es1:9200,http://es2:9200")
        monkeypatch.setenv("ES_INDEX_PREFIX", "custom_prefix")
        
        config = ElasticsearchConfig.from_env()
        
        assert len(config.hosts) == 2
        assert "http://es1:9200" in config.hosts
        assert config.index_prefix == "custom_prefix"


class TestOpenAIConfig:
    """Tests for OpenAI configuration"""
    
    def test_default_values(self):
        """Test default OpenAI configuration values"""
        config = OpenAIConfig()
        assert config.model == "text-embedding-3-small"
        assert config.embedding_dimensions == 1536
        assert config.batch_size == 100
    
    def test_is_configured_with_api_key(self):
        """Test is_configured with API key"""
        config = OpenAIConfig(api_key="sk-test-key")
        assert config.is_configured() == True
    
    def test_is_configured_without_api_key(self):
        """Test is_configured without API key"""
        config = OpenAIConfig()
        assert config.is_configured() == False


class TestAuthConfig:
    """Tests for authentication configuration"""
    
    def test_default_values(self):
        """Test default auth configuration"""
        config = AuthConfig()
        assert config.enabled == False
        assert config.rate_limit_enabled == True
        assert config.rate_limit_requests == 100
        assert config.jwt_algorithm == "HS256"
    
    def test_is_configured_with_api_keys(self):
        """Test is_configured with API keys"""
        config = AuthConfig(enabled=True, api_keys=["key1", "key2"])
        assert config.is_configured() == True
    
    def test_is_configured_with_jwt_secret(self):
        """Test is_configured with JWT secret"""
        config = AuthConfig(enabled=True, jwt_secret="my-secret")
        assert config.is_configured() == True
    
    def test_is_configured_disabled(self):
        """Test is_configured when disabled"""
        config = AuthConfig(enabled=False, api_keys=["key1"])
        assert config.is_configured() == False


class TestServerConfig:
    """Tests for server configuration"""
    
    def test_default_values(self):
        """Test default server configuration"""
        config = ServerConfig()
        assert config.port == 9150
        assert config.host == "0.0.0.0"
        assert config.log_level == "INFO"
        assert config.cors_enabled == True
    
    def test_from_env(self, monkeypatch):
        """Test loading from environment"""
        monkeypatch.setenv("MCP_PORT", "8080")
        monkeypatch.setenv("LOG_LEVEL", "DEBUG")
        
        config = ServerConfig.from_env()
        
        assert config.port == 8080
        assert config.log_level == "DEBUG"


class TestSettings:
    """Tests for complete Settings class"""
    
    def test_from_env(self):
        """Test loading complete settings from environment"""
        settings = Settings.from_env()
        
        assert settings.hana is not None
        assert settings.elasticsearch is not None
        assert settings.openai is not None
        assert settings.auth is not None
        assert settings.audit is not None
        assert settings.server is not None
    
    def test_to_dict_masks_passwords(self):
        """Test to_dict masks sensitive values"""
        settings = Settings(
            hana=HANAConfig(
                host="test.hana.cloud.sap",
                user="admin",
                password="secret-password"
            )
        )
        
        result = settings.to_dict()
        
        assert result["hana"]["password"] == "***"
        assert result["hana"]["host"] == "test.hana.cloud.sap"
    
    def test_validate_returns_warnings(self):
        """Test validate returns appropriate warnings"""
        settings = Settings()
        issues = settings.validate()
        
        assert "warnings" in issues
        assert "errors" in issues
        # Should have warnings about unconfigured services
        assert len(issues["warnings"]) > 0
    
    def test_singleton_pattern(self):
        """Test get_settings returns singleton"""
        reload_settings()  # Reset singleton
        
        settings1 = get_settings()
        settings2 = get_settings()
        
        assert settings1 is settings2