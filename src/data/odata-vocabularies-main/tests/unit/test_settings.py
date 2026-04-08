"""
Unit tests for configuration settings.
"""

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from config.settings import (
    Settings, HANAConfig, OpenAIConfig,
    AuthConfig, AuditConfig, ServerConfig, get_settings, reload_settings
)


class TestHANAConfig:
    """Tests for HANA configuration."""

    def test_default_values(self):
        config = HANAConfig()

        assert config.host == ""
        assert config.port == 443
        assert config.encrypt is True
        assert config.connection_timeout == 30
        assert config.vector_schema == ""
        assert config.vector_table_prefix == "ODATA"
        assert config.vector_embedding_dimensions == 1536

    def test_is_configured_false_when_empty(self):
        config = HANAConfig()
        assert config.is_configured() is False
        assert config.is_vector_configured() is False

    def test_is_configured_true_with_credentials(self):
        config = HANAConfig(
            host="test.hana.cloud.sap",
            user="admin",
            password="secret",
        )
        assert config.is_configured() is True
        assert config.is_vector_configured() is False

    def test_is_vector_configured_with_schema_fallback(self):
        config = HANAConfig(
            host="test.hana.cloud.sap",
            user="admin",
            password="secret",
            schema="MAIN",
        )

        assert config.get_vector_schema() == "MAIN"
        assert config.is_vector_configured() is True

    def test_is_vector_configured_with_explicit_vector_schema(self):
        config = HANAConfig(
            host="test.hana.cloud.sap",
            user="admin",
            password="secret",
            schema="MAIN",
            vector_schema="VECTOR",
            vector_table_prefix="VOCAB",
            vector_embedding_dimensions=3072,
        )

        assert config.get_vector_schema() == "VECTOR"
        assert config.is_vector_configured() is True
        assert config.vector_table_prefix == "VOCAB"
        assert config.vector_embedding_dimensions == 3072

    def test_from_env(self, monkeypatch):
        monkeypatch.setenv("HANA_HOST", "env-host.hana.cloud.sap")
        monkeypatch.setenv("HANA_PORT", "30015")
        monkeypatch.setenv("HANA_USER", "env_user")
        monkeypatch.setenv("HANA_PASSWORD", "env_password")
        monkeypatch.setenv("HANA_SCHEMA", "MAIN")
        monkeypatch.setenv("HANA_VECTOR_SCHEMA", "VECTOR")
        monkeypatch.setenv("HANA_VECTOR_TABLE_PREFIX", "VOCAB")
        monkeypatch.setenv("HANA_VECTOR_EMBEDDING_DIM", "3072")

        config = HANAConfig.from_env()

        assert config.host == "env-host.hana.cloud.sap"
        assert config.port == 30015
        assert config.user == "env_user"
        assert config.password == "env_password"
        assert config.schema == "MAIN"
        assert config.vector_schema == "VECTOR"
        assert config.vector_table_prefix == "VOCAB"
        assert config.vector_embedding_dimensions == 3072


class TestHANAConfigVectorFields:
    """Tests for HANA vector store configuration fields"""
    
    def test_default_vector_values(self):
        """Test default vector store field values"""
        config = HANAConfig()
        assert config.vector_schema == ""
        assert config.vector_table_prefix == "ODATA"
        assert config.vector_embedding_dimensions == 1536
    
    def test_get_vector_schema_returns_vector_schema(self):
        """Test get_vector_schema prefers vector_schema"""
        config = HANAConfig(schema="MAIN", vector_schema="VEC")
        assert config.get_vector_schema() == "VEC"
    
    def test_get_vector_schema_falls_back(self):
        """Test get_vector_schema falls back to schema"""
        config = HANAConfig(schema="MAIN", vector_schema="")
        assert config.get_vector_schema() == "MAIN"
    
    def test_is_vector_configured_true(self):
        """Test is_vector_configured with full credentials and schema"""
        config = HANAConfig(
            host="h.hana.cloud.sap", user="u", password="p",
            schema="S", vector_schema="S"
        )
        assert config.is_vector_configured() == True
    
    def test_is_vector_configured_false_no_creds(self):
        """Test is_vector_configured False without HANA credentials"""
        config = HANAConfig(vector_schema="S")
        assert config.is_vector_configured() == False
    
    def test_is_vector_configured_false_no_schema(self):
        """Test is_vector_configured False without any schema"""
        config = HANAConfig(
            host="h.hana.cloud.sap", user="u", password="p",
            schema="", vector_schema=""
        )
        assert config.is_vector_configured() == False
    
    def test_from_env_vector_fields(self, monkeypatch):
        """Test loading vector fields from environment"""
        monkeypatch.setenv("HANA_HOST", "h.hana.cloud.sap")
        monkeypatch.setenv("HANA_USER", "u")
        monkeypatch.setenv("HANA_PASSWORD", "p")
        monkeypatch.setenv("HANA_SCHEMA", "MAIN")
        monkeypatch.setenv("HANA_VECTOR_SCHEMA", "VEC")
        monkeypatch.setenv("HANA_VECTOR_TABLE_PREFIX", "CUSTOM")
        monkeypatch.setenv("HANA_VECTOR_EMBEDDING_DIM", "768")
        
        config = HANAConfig.from_env()
        
        assert config.vector_schema == "VEC"
        assert config.vector_table_prefix == "CUSTOM"
        assert config.vector_embedding_dimensions == 768


class TestOpenAIConfig:
    """Tests for OpenAI configuration."""

    def test_default_values(self):
        config = OpenAIConfig()
        assert config.model == "text-embedding-3-small"
        assert config.embedding_dimensions == 1536
        assert config.batch_size == 100

    def test_is_configured_with_api_key(self):
        config = OpenAIConfig(api_key="sk-test-key")
        assert config.is_configured() is True

    def test_is_configured_without_api_key(self):
        config = OpenAIConfig()
        assert config.is_configured() is False


class TestAuthConfig:
    """Tests for authentication configuration."""

    def test_default_values(self):
        config = AuthConfig()
        assert config.enabled is False
        assert config.rate_limit_enabled is True
        assert config.rate_limit_requests == 100
        assert config.jwt_algorithm == "HS256"

    def test_is_configured_with_api_keys(self):
        config = AuthConfig(enabled=True, api_keys=["key1", "key2"])
        assert config.is_configured() is True

    def test_is_configured_with_jwt_secret(self):
        config = AuthConfig(enabled=True, jwt_secret="my-secret")
        assert config.is_configured() is True

    def test_is_configured_disabled(self):
        config = AuthConfig(enabled=False, api_keys=["key1"])
        assert config.is_configured() is False


class TestAuditConfig:
    """Tests for audit configuration."""

    def test_default_values(self):
        config = AuditConfig()
        assert config.enabled is True
        assert config.syslog_enabled is False
        assert config.hana_enabled is False
        assert config.hana_table == "ODATA_AUDIT"

    def test_from_env(self, monkeypatch):
        monkeypatch.setenv("AUDIT_HANA_ENABLED", "true")
        monkeypatch.setenv("AUDIT_HANA_TABLE", "CUSTOM_AUDIT")

        config = AuditConfig.from_env()

        assert config.hana_enabled is True
        assert config.hana_table == "CUSTOM_AUDIT"


class TestServerConfig:
    """Tests for server configuration."""

    def test_default_values(self):
        config = ServerConfig()
        assert config.port == 9150
        assert config.host == "0.0.0.0"
        assert config.log_level == "INFO"
        assert config.cors_enabled is True

    def test_from_env(self, monkeypatch):
        monkeypatch.setenv("MCP_PORT", "8080")
        monkeypatch.setenv("LOG_LEVEL", "DEBUG")

        config = ServerConfig.from_env()

        assert config.port == 8080
        assert config.log_level == "DEBUG"


class TestSettings:
    """Tests for complete Settings class."""

    def test_from_env(self):
        settings = Settings.from_env()

        assert settings.hana is not None
        assert settings.hana.vector_table_prefix  # vector fields live on HANAConfig
        assert settings.openai is not None
        assert settings.audit is not None
        assert settings.server is not None

    def test_to_dict_masks_passwords(self):
        settings = Settings(
            hana=HANAConfig(
                host="test.hana.cloud.sap",
                user="admin",
                password="secret-password",
                schema="MAIN",
                vector_schema="VECTOR",
            )
        )

        result = settings.to_dict()

        assert result["hana"]["password"] == "***"
        assert result["hana"]["host"] == "test.hana.cloud.sap"
        assert result["hana"]["vector_store"]["schema"] == "VECTOR"
        assert result["hana"]["vector_store"]["configured"] is True

    def test_validate_returns_warnings(self):
        settings = Settings()
        issues = settings.validate()

        assert "warnings" in issues
        assert "errors" in issues
        assert len(issues["warnings"]) > 0

    def test_from_file_migrates_legacy_hana_vector_block(self, tmp_path):
        config_path = tmp_path / "settings.json"
        config_path.write_text(
            """
            {
              "hana": {
                "host": "hana.cloud.sap",
                "user": "admin",
                "password": "secret",
                "schema": "MAIN"
              },
              "hana_vector": {
                "schema": "VECTOR",
                "table_prefix": "VOCAB",
                "embedding_dimensions": 2048
              }
            }
            """.strip()
        )

        settings = Settings.from_file(str(config_path))

        assert settings.hana.get_vector_schema() == "VECTOR"
        assert settings.hana.vector_table_prefix == "VOCAB"
        assert settings.hana.vector_embedding_dimensions == 2048

    def test_singleton_pattern(self):
        reload_settings()

        settings1 = get_settings()
        settings2 = get_settings()

        assert settings1 is settings2
