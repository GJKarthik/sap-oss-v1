"""
Unit tests for mTLS middleware.

Day 42 - Week 9 Security Hardening
45 tests covering certificate management, SSL context, and mTLS client.
"""

import os
import ssl
import tempfile
import pytest
from datetime import datetime, timedelta
from unittest.mock import Mock, patch, AsyncMock, MagicMock

from middleware.mtls import (
    CertificateType,
    CertificateStatus,
    CertificateInfo,
    MTLSConfig,
    CertificateManager,
    MTLSContext,
    MTLSClient,
    get_mtls_client,
    get_mtls_config,
)


# =============================================================================
# CertificateType Tests (3 tests)
# =============================================================================

class TestCertificateType:
    """Tests for CertificateType enum."""
    
    def test_rsa_types(self):
        """Test RSA certificate types."""
        assert CertificateType.RSA_2048.value == "rsa_2048"
        assert CertificateType.RSA_4096.value == "rsa_4096"
    
    def test_ecdsa_types(self):
        """Test ECDSA certificate types."""
        assert CertificateType.ECDSA_P256.value == "ecdsa_p256"
        assert CertificateType.ECDSA_P384.value == "ecdsa_p384"
    
    def test_all_types_defined(self):
        """Test all certificate types are defined."""
        types = list(CertificateType)
        assert len(types) == 4


# =============================================================================
# CertificateStatus Tests (3 tests)
# =============================================================================

class TestCertificateStatus:
    """Tests for CertificateStatus enum."""
    
    def test_valid_status(self):
        """Test valid certificate status."""
        assert CertificateStatus.VALID.value == "valid"
    
    def test_invalid_statuses(self):
        """Test invalid certificate statuses."""
        assert CertificateStatus.EXPIRED.value == "expired"
        assert CertificateStatus.NOT_YET_VALID.value == "not_yet_valid"
        assert CertificateStatus.REVOKED.value == "revoked"
        assert CertificateStatus.INVALID_CHAIN.value == "invalid_chain"
    
    def test_all_statuses_defined(self):
        """Test all statuses are defined."""
        statuses = list(CertificateStatus)
        assert len(statuses) == 6


# =============================================================================
# CertificateInfo Tests (8 tests)
# =============================================================================

class TestCertificateInfo:
    """Tests for CertificateInfo dataclass."""
    
    @pytest.fixture
    def valid_cert_info(self):
        """Create valid certificate info."""
        now = datetime.utcnow()
        return CertificateInfo(
            subject="CN=test.example.com, O=SAP",
            issuer="CN=test.example.com, O=SAP",
            serial_number=12345678901234567890,
            not_before=now - timedelta(days=30),
            not_after=now + timedelta(days=335),
            fingerprint_sha256="abc123def456",
            key_type="RSA",
            key_size=2048,
            san_dns_names=["test.example.com", "*.example.com"],
            san_ips=["10.0.0.1"],
        )
    
    @pytest.fixture
    def expired_cert_info(self):
        """Create expired certificate info."""
        now = datetime.utcnow()
        return CertificateInfo(
            subject="CN=expired.example.com",
            issuer="CN=expired.example.com",
            serial_number=1,
            not_before=now - timedelta(days=400),
            not_after=now - timedelta(days=35),
            fingerprint_sha256="expired123",
            key_type="RSA",
            key_size=2048,
        )
    
    def test_is_valid_true(self, valid_cert_info):
        """Test is_valid returns True for valid cert."""
        assert valid_cert_info.is_valid is True
    
    def test_is_valid_false_expired(self, expired_cert_info):
        """Test is_valid returns False for expired cert."""
        assert expired_cert_info.is_valid is False
    
    def test_is_valid_false_not_yet_valid(self):
        """Test is_valid returns False for future cert."""
        now = datetime.utcnow()
        cert_info = CertificateInfo(
            subject="CN=future",
            issuer="CN=future",
            serial_number=1,
            not_before=now + timedelta(days=30),
            not_after=now + timedelta(days=395),
            fingerprint_sha256="future123",
            key_type="RSA",
            key_size=2048,
        )
        assert cert_info.is_valid is False
    
    def test_days_until_expiry_positive(self, valid_cert_info):
        """Test days_until_expiry is positive for valid cert."""
        assert valid_cert_info.days_until_expiry > 0
        assert valid_cert_info.days_until_expiry <= 365
    
    def test_days_until_expiry_negative(self, expired_cert_info):
        """Test days_until_expiry is negative for expired cert."""
        assert expired_cert_info.days_until_expiry < 0
    
    def test_to_dict(self, valid_cert_info):
        """Test to_dict conversion."""
        d = valid_cert_info.to_dict()
        assert d["subject"] == "CN=test.example.com, O=SAP"
        assert d["key_type"] == "RSA"
        assert d["key_size"] == 2048
        assert d["is_valid"] is True
        assert "days_until_expiry" in d
    
    def test_san_fields(self, valid_cert_info):
        """Test SAN fields are properly set."""
        assert len(valid_cert_info.san_dns_names) == 2
        assert "test.example.com" in valid_cert_info.san_dns_names
        assert len(valid_cert_info.san_ips) == 1
        assert "10.0.0.1" in valid_cert_info.san_ips
    
    def test_default_san_fields(self):
        """Test default SAN fields are empty lists."""
        cert_info = CertificateInfo(
            subject="CN=test",
            issuer="CN=test",
            serial_number=1,
            not_before=datetime.utcnow(),
            not_after=datetime.utcnow() + timedelta(days=365),
            fingerprint_sha256="abc",
            key_type="RSA",
            key_size=2048,
        )
        assert cert_info.san_dns_names == []
        assert cert_info.san_ips == []


# =============================================================================
# MTLSConfig Tests (8 tests)
# =============================================================================

class TestMTLSConfig:
    """Tests for MTLSConfig dataclass."""
    
    def test_default_config(self):
        """Test default configuration values."""
        config = MTLSConfig()
        assert config.enabled is True
        assert config.cert_path == "/etc/ssl/certs/client.crt"
        assert config.key_path == "/etc/ssl/private/client.key"
        assert config.verify_hostname is True
    
    def test_custom_config(self):
        """Test custom configuration values."""
        config = MTLSConfig(
            enabled=False,
            cert_path="/custom/cert.pem",
            key_path="/custom/key.pem",
            verify_hostname=False,
        )
        assert config.enabled is False
        assert config.cert_path == "/custom/cert.pem"
    
    def test_cipher_suites_default(self):
        """Test default cipher suites."""
        config = MTLSConfig()
        assert len(config.cipher_suites) > 0
        assert "TLS_AES_256_GCM_SHA384" in config.cipher_suites
    
    def test_rotation_thresholds(self):
        """Test rotation threshold defaults."""
        config = MTLSConfig()
        assert config.rotation_warning_days == 30
        assert config.rotation_critical_days == 7
    
    def test_from_env_enabled(self):
        """Test from_env with MTLS enabled."""
        with patch.dict(os.environ, {"MTLS_ENABLED": "true"}):
            config = MTLSConfig.from_env()
            assert config.enabled is True
    
    def test_from_env_disabled(self):
        """Test from_env with MTLS disabled."""
        with patch.dict(os.environ, {"MTLS_ENABLED": "false"}):
            config = MTLSConfig.from_env()
            assert config.enabled is False
    
    def test_from_env_custom_paths(self):
        """Test from_env with custom paths."""
        with patch.dict(os.environ, {
            "MTLS_CERT_PATH": "/app/certs/client.crt",
            "MTLS_KEY_PATH": "/app/certs/client.key",
        }):
            config = MTLSConfig.from_env()
            assert config.cert_path == "/app/certs/client.crt"
            assert config.key_path == "/app/certs/client.key"
    
    def test_from_env_verify_hostname(self):
        """Test from_env verify_hostname setting."""
        with patch.dict(os.environ, {"MTLS_VERIFY_HOSTNAME": "false"}):
            config = MTLSConfig.from_env()
            assert config.verify_hostname is False


# =============================================================================
# CertificateManager Tests (10 tests)
# =============================================================================

class TestCertificateManager:
    """Tests for CertificateManager class."""
    
    @pytest.fixture
    def manager(self):
        """Create certificate manager."""
        config = MTLSConfig()
        return CertificateManager(config)
    
    def test_init(self, manager):
        """Test CertificateManager initialization."""
        assert manager.config is not None
        assert manager._cert_cache == {}
    
    def test_generate_self_signed_ecdsa(self, manager):
        """Test generating ECDSA self-signed certificate."""
        cert, key = manager.generate_self_signed_cert(
            common_name="test.example.com",
            key_type=CertificateType.ECDSA_P256,
        )
        assert cert is not None
        assert key is not None
    
    def test_generate_self_signed_rsa(self, manager):
        """Test generating RSA self-signed certificate."""
        cert, key = manager.generate_self_signed_cert(
            common_name="test.example.com",
            key_type=CertificateType.RSA_2048,
        )
        assert cert is not None
        assert key is not None
    
    def test_generate_with_sans(self, manager):
        """Test generating certificate with SANs."""
        cert, key = manager.generate_self_signed_cert(
            common_name="test.example.com",
            san_dns_names=["api.example.com", "*.example.com"],
        )
        info = manager.get_certificate_info(cert)
        assert "api.example.com" in info.san_dns_names
    
    def test_get_certificate_info(self, manager):
        """Test extracting certificate info."""
        cert, _ = manager.generate_self_signed_cert(
            common_name="info-test.example.com",
            organization="Test Org",
        )
        info = manager.get_certificate_info(cert)
        assert "info-test.example.com" in info.subject
        assert info.key_type in ["RSA", "ECDSA-secp256r1"]
    
    def test_validate_certificate_valid(self, manager):
        """Test validating a valid certificate."""
        cert, _ = manager.generate_self_signed_cert(
            common_name="valid.example.com",
            validity_days=365,
        )
        status, message = manager.validate_certificate(cert)
        assert status == CertificateStatus.VALID
    
    def test_check_rotation_not_needed(self, manager):
        """Test rotation not needed for fresh cert."""
        cert, _ = manager.generate_self_signed_cert(
            common_name="fresh.example.com",
            validity_days=365,
        )
        needs_rotation, message = manager.check_rotation_needed(cert)
        assert needs_rotation is False
        assert "valid for" in message
    
    def test_check_rotation_warning(self, manager):
        """Test rotation warning for near-expiry cert."""
        manager.config.rotation_warning_days = 400
        cert, _ = manager.generate_self_signed_cert(
            common_name="warning.example.com",
            validity_days=365,
        )
        needs_rotation, message = manager.check_rotation_needed(cert)
        assert needs_rotation is True
        assert "WARNING" in message
    
    def test_save_and_load_certificate(self, manager):
        """Test saving and loading certificate."""
        cert, key = manager.generate_self_signed_cert(
            common_name="save-test.example.com",
        )
        
        with tempfile.NamedTemporaryFile(suffix=".crt", delete=False) as f:
            cert_path = f.name
        
        try:
            manager.save_certificate(cert, cert_path)
            loaded_cert = manager.load_certificate(cert_path)
            assert loaded_cert.serial_number == cert.serial_number
        finally:
            os.unlink(cert_path)
    
    def test_save_and_load_private_key(self, manager):
        """Test saving and loading private key."""
        _, key = manager.generate_self_signed_cert(
            common_name="key-test.example.com",
        )
        
        with tempfile.NamedTemporaryFile(suffix=".key", delete=False) as f:
            key_path = f.name
        
        try:
            manager.save_private_key(key, key_path)
            loaded_key = manager.load_private_key(key_path)
            assert loaded_key is not None
        finally:
            os.unlink(key_path)


# =============================================================================
# MTLSContext Tests (6 tests)
# =============================================================================

class TestMTLSContext:
    """Tests for MTLSContext class."""
    
    @pytest.fixture
    def context(self):
        """Create mTLS context."""
        config = MTLSConfig()
        manager = CertificateManager(config)
        return MTLSContext(config, manager)
    
    def test_init(self, context):
        """Test MTLSContext initialization."""
        assert context.config is not None
        assert context.cert_manager is not None
        assert context._ssl_context is None
    
    def test_create_ssl_context_tls12(self):
        """Test creating SSL context with TLS 1.2."""
        config = MTLSConfig(min_protocol_version="TLSv1.2")
        manager = CertificateManager(config)
        context = MTLSContext(config, manager)
        
        ssl_ctx = context.create_ssl_context()
        assert ssl_ctx.minimum_version >= ssl.TLSVersion.TLSv1_2
    
    def test_create_ssl_context_tls13(self):
        """Test creating SSL context with TLS 1.3."""
        config = MTLSConfig(min_protocol_version="TLSv1.3")
        manager = CertificateManager(config)
        context = MTLSContext(config, manager)
        
        ssl_ctx = context.create_ssl_context()
        assert ssl_ctx.minimum_version == ssl.TLSVersion.TLSv1_3
    
    def test_get_ssl_context_caches(self, context):
        """Test SSL context is cached."""
        ctx1 = context.get_ssl_context()
        ctx2 = context.get_ssl_context()
        assert ctx1 is ctx2
    
    def test_refresh_ssl_context(self, context):
        """Test refreshing SSL context."""
        ctx1 = context.get_ssl_context()
        context.refresh_ssl_context()
        ctx2 = context.get_ssl_context()
        assert ctx1 is not ctx2
    
    def test_verify_mode(self, context):
        """Test SSL context verify mode."""
        ssl_ctx = context.create_ssl_context()
        assert ssl_ctx.verify_mode == ssl.CERT_REQUIRED


# =============================================================================
# MTLSClient Tests (7 tests)
# =============================================================================

class TestMTLSClient:
    """Tests for MTLSClient class."""
    
    @pytest.fixture
    def client(self):
        """Create mTLS client."""
        config = MTLSConfig(enabled=False)  # Disable for testing
        return MTLSClient(config)
    
    def test_init(self, client):
        """Test MTLSClient initialization."""
        assert client.config is not None
        assert client.cert_manager is not None
        assert client._client is None
    
    @pytest.mark.asyncio
    async def test_get_client_creates_httpx_client(self, client):
        """Test get_client creates httpx AsyncClient."""
        http_client = await client.get_client()
        assert http_client is not None
        await client.close()
    
    @pytest.mark.asyncio
    async def test_get_client_caches(self, client):
        """Test get_client caches the client."""
        client1 = await client.get_client()
        client2 = await client.get_client()
        assert client1 is client2
        await client.close()
    
    @pytest.mark.asyncio
    async def test_close_clears_client(self, client):
        """Test close clears the client."""
        await client.get_client()
        assert client._client is not None
        await client.close()
        assert client._client is None
    
    def test_check_certificate_health_missing(self, client):
        """Test certificate health when cert is missing."""
        health = client.check_certificate_health()
        assert health["status"] == "missing"
    
    def test_get_client_certificate_info_missing(self, client):
        """Test get_client_certificate_info when cert is missing."""
        info = client.get_client_certificate_info()
        assert info is None
    
    def test_check_certificate_health_with_cert(self):
        """Test certificate health with valid cert."""
        config = MTLSConfig()
        manager = CertificateManager(config)
        cert, key = manager.generate_self_signed_cert(
            common_name="health-test.example.com"
        )
        
        with tempfile.NamedTemporaryFile(suffix=".crt", delete=False) as f:
            cert_path = f.name
        with tempfile.NamedTemporaryFile(suffix=".key", delete=False) as f:
            key_path = f.name
        
        try:
            manager.save_certificate(cert, cert_path)
            manager.save_private_key(key, key_path)
            
            config = MTLSConfig(cert_path=cert_path, key_path=key_path)
            client = MTLSClient(config)
            
            health = client.check_certificate_health()
            assert health["status"] == "valid"
            assert health["rotation_needed"] is False
        finally:
            os.unlink(cert_path)
            os.unlink(key_path)


# =============================================================================
# Module Functions Tests (3 tests)
# =============================================================================

class TestModuleFunctions:
    """Tests for module-level functions."""
    
    def test_get_mtls_config(self):
        """Test get_mtls_config returns config."""
        config = get_mtls_config()
        assert isinstance(config, MTLSConfig)
    
    def test_get_mtls_client_singleton(self):
        """Test get_mtls_client returns singleton."""
        # Reset singleton
        import middleware.mtls as mtls_module
        mtls_module._mtls_client = None
        
        client1 = get_mtls_client()
        client2 = get_mtls_client()
        assert client1 is client2
    
    def test_get_mtls_client_creates_client(self):
        """Test get_mtls_client creates client."""
        import middleware.mtls as mtls_module
        mtls_module._mtls_client = None
        
        client = get_mtls_client()
        assert isinstance(client, MTLSClient)


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - CertificateType: 3 tests
# - CertificateStatus: 3 tests
# - CertificateInfo: 8 tests
# - MTLSConfig: 8 tests
# - CertificateManager: 10 tests
# - MTLSContext: 6 tests
# - MTLSClient: 7 tests