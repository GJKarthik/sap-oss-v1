"""
mTLS (Mutual TLS) Middleware for Service-to-Service Authentication.

Day 42 Implementation - Week 9 Security Hardening
Provides certificate-based authentication for backend connections.
"""

import ssl
import os
import hashlib
import logging
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, Dict, Any, Tuple
from dataclasses import dataclass, field
from enum import Enum
import asyncio
from functools import lru_cache

import httpx
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, ec
from cryptography.hazmat.backends import default_backend

logger = logging.getLogger(__name__)


class CertificateType(str, Enum):
    """Certificate key types."""
    RSA_2048 = "rsa_2048"
    RSA_4096 = "rsa_4096"
    ECDSA_P256 = "ecdsa_p256"
    ECDSA_P384 = "ecdsa_p384"


class CertificateStatus(str, Enum):
    """Certificate validation status."""
    VALID = "valid"
    EXPIRED = "expired"
    NOT_YET_VALID = "not_yet_valid"
    REVOKED = "revoked"
    INVALID_CHAIN = "invalid_chain"
    UNKNOWN = "unknown"


@dataclass
class CertificateInfo:
    """Certificate metadata."""
    subject: str
    issuer: str
    serial_number: int
    not_before: datetime
    not_after: datetime
    fingerprint_sha256: str
    key_type: str
    key_size: int
    san_dns_names: list = field(default_factory=list)
    san_ips: list = field(default_factory=list)
    
    @property
    def is_valid(self) -> bool:
        """Check if certificate is currently valid."""
        now = datetime.utcnow()
        return self.not_before <= now <= self.not_after
    
    @property
    def days_until_expiry(self) -> int:
        """Days until certificate expires."""
        return (self.not_after - datetime.utcnow()).days
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "subject": self.subject,
            "issuer": self.issuer,
            "serial_number": str(self.serial_number),
            "not_before": self.not_before.isoformat(),
            "not_after": self.not_after.isoformat(),
            "fingerprint_sha256": self.fingerprint_sha256,
            "key_type": self.key_type,
            "key_size": self.key_size,
            "san_dns_names": self.san_dns_names,
            "san_ips": self.san_ips,
            "is_valid": self.is_valid,
            "days_until_expiry": self.days_until_expiry,
        }


@dataclass
class MTLSConfig:
    """mTLS configuration."""
    enabled: bool = True
    cert_path: str = "/etc/ssl/certs/client.crt"
    key_path: str = "/etc/ssl/private/client.key"
    ca_bundle_path: str = "/etc/ssl/certs/ca-bundle.crt"
    verify_hostname: bool = True
    verify_depth: int = 3
    min_protocol_version: str = "TLSv1.2"
    cipher_suites: list = field(default_factory=lambda: [
        "TLS_AES_256_GCM_SHA384",
        "TLS_CHACHA20_POLY1305_SHA256",
        "TLS_AES_128_GCM_SHA256",
        "ECDHE-ECDSA-AES256-GCM-SHA384",
        "ECDHE-RSA-AES256-GCM-SHA384",
    ])
    rotation_warning_days: int = 30
    rotation_critical_days: int = 7
    
    @classmethod
    def from_env(cls) -> "MTLSConfig":
        """Create config from environment variables."""
        return cls(
            enabled=os.getenv("MTLS_ENABLED", "true").lower() == "true",
            cert_path=os.getenv("MTLS_CERT_PATH", "/etc/ssl/certs/client.crt"),
            key_path=os.getenv("MTLS_KEY_PATH", "/etc/ssl/private/client.key"),
            ca_bundle_path=os.getenv("MTLS_CA_BUNDLE_PATH", "/etc/ssl/certs/ca-bundle.crt"),
            verify_hostname=os.getenv("MTLS_VERIFY_HOSTNAME", "true").lower() == "true",
            verify_depth=int(os.getenv("MTLS_VERIFY_DEPTH", "3")),
            rotation_warning_days=int(os.getenv("MTLS_ROTATION_WARNING_DAYS", "30")),
            rotation_critical_days=int(os.getenv("MTLS_ROTATION_CRITICAL_DAYS", "7")),
        )


class CertificateManager:
    """Manages X.509 certificates for mTLS."""
    
    def __init__(self, config: MTLSConfig):
        self.config = config
        self._cert_cache: Dict[str, CertificateInfo] = {}
        self._last_rotation_check: Optional[datetime] = None
        
    def load_certificate(self, cert_path: str) -> x509.Certificate:
        """Load X.509 certificate from file."""
        with open(cert_path, "rb") as f:
            cert_data = f.read()
        
        # Try PEM format first
        try:
            return x509.load_pem_x509_certificate(cert_data, default_backend())
        except ValueError:
            # Try DER format
            return x509.load_der_x509_certificate(cert_data, default_backend())
    
    def load_private_key(self, key_path: str, password: Optional[bytes] = None):
        """Load private key from file."""
        with open(key_path, "rb") as f:
            key_data = f.read()
        
        try:
            return serialization.load_pem_private_key(
                key_data, password=password, backend=default_backend()
            )
        except ValueError:
            return serialization.load_der_private_key(
                key_data, password=password, backend=default_backend()
            )
    
    def get_certificate_info(self, cert: x509.Certificate) -> CertificateInfo:
        """Extract certificate metadata."""
        # Get subject
        subject_parts = []
        for attr in cert.subject:
            subject_parts.append(f"{attr.oid._name}={attr.value}")
        subject = ", ".join(subject_parts)
        
        # Get issuer
        issuer_parts = []
        for attr in cert.issuer:
            issuer_parts.append(f"{attr.oid._name}={attr.value}")
        issuer = ", ".join(issuer_parts)
        
        # Get fingerprint
        fingerprint = cert.fingerprint(hashes.SHA256()).hex()
        
        # Get key info
        public_key = cert.public_key()
        if isinstance(public_key, rsa.RSAPublicKey):
            key_type = "RSA"
            key_size = public_key.key_size
        elif isinstance(public_key, ec.EllipticCurvePublicKey):
            key_type = f"ECDSA-{public_key.curve.name}"
            key_size = public_key.curve.key_size
        else:
            key_type = "Unknown"
            key_size = 0
        
        # Get SANs
        san_dns_names = []
        san_ips = []
        try:
            san_ext = cert.extensions.get_extension_for_class(
                x509.SubjectAlternativeName
            )
            for name in san_ext.value:
                if isinstance(name, x509.DNSName):
                    san_dns_names.append(name.value)
                elif isinstance(name, x509.IPAddress):
                    san_ips.append(str(name.value))
        except x509.ExtensionNotFound:
            pass
        
        return CertificateInfo(
            subject=subject,
            issuer=issuer,
            serial_number=cert.serial_number,
            not_before=cert.not_valid_before,
            not_after=cert.not_valid_after,
            fingerprint_sha256=fingerprint,
            key_type=key_type,
            key_size=key_size,
            san_dns_names=san_dns_names,
            san_ips=san_ips,
        )
    
    def validate_certificate(self, cert: x509.Certificate) -> Tuple[CertificateStatus, str]:
        """Validate certificate status."""
        now = datetime.utcnow()
        
        # Check validity period
        if now < cert.not_valid_before:
            return CertificateStatus.NOT_YET_VALID, "Certificate not yet valid"
        
        if now > cert.not_valid_after:
            return CertificateStatus.EXPIRED, "Certificate has expired"
        
        # TODO: Add CRL/OCSP checking for production
        
        return CertificateStatus.VALID, "Certificate is valid"
    
    def check_rotation_needed(self, cert: x509.Certificate) -> Tuple[bool, str]:
        """Check if certificate rotation is needed."""
        info = self.get_certificate_info(cert)
        
        if info.days_until_expiry <= self.config.rotation_critical_days:
            return True, f"CRITICAL: Certificate expires in {info.days_until_expiry} days"
        
        if info.days_until_expiry <= self.config.rotation_warning_days:
            return True, f"WARNING: Certificate expires in {info.days_until_expiry} days"
        
        return False, f"Certificate valid for {info.days_until_expiry} days"
    
    def generate_self_signed_cert(
        self,
        common_name: str,
        organization: str = "SAP",
        validity_days: int = 365,
        key_type: CertificateType = CertificateType.ECDSA_P256,
        san_dns_names: list = None,
    ) -> Tuple[x509.Certificate, Any]:
        """Generate self-signed certificate for development/testing."""
        san_dns_names = san_dns_names or []
        
        # Generate private key
        if key_type in (CertificateType.RSA_2048, CertificateType.RSA_4096):
            key_size = 2048 if key_type == CertificateType.RSA_2048 else 4096
            private_key = rsa.generate_private_key(
                public_exponent=65537,
                key_size=key_size,
                backend=default_backend()
            )
        else:
            curve = ec.SECP256R1() if key_type == CertificateType.ECDSA_P256 else ec.SECP384R1()
            private_key = ec.generate_private_key(curve, default_backend())
        
        # Build certificate
        subject = issuer = x509.Name([
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, organization),
            x509.NameAttribute(NameOID.COMMON_NAME, common_name),
        ])
        
        now = datetime.utcnow()
        
        builder = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(issuer)
            .public_key(private_key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now)
            .not_valid_after(now + timedelta(days=validity_days))
        )
        
        # Add SANs
        if san_dns_names:
            san_list = [x509.DNSName(name) for name in san_dns_names]
            builder = builder.add_extension(
                x509.SubjectAlternativeName(san_list),
                critical=False,
            )
        
        # Add basic constraints
        builder = builder.add_extension(
            x509.BasicConstraints(ca=False, path_length=None),
            critical=True,
        )
        
        # Sign certificate
        if isinstance(private_key, rsa.RSAPrivateKey):
            algorithm = hashes.SHA256()
        else:
            algorithm = hashes.SHA256()
        
        cert = builder.sign(private_key, algorithm, default_backend())
        
        return cert, private_key
    
    def save_certificate(self, cert: x509.Certificate, path: str):
        """Save certificate to file."""
        pem_data = cert.public_bytes(serialization.Encoding.PEM)
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "wb") as f:
            f.write(pem_data)
    
    def save_private_key(
        self,
        private_key,
        path: str,
        password: Optional[bytes] = None
    ):
        """Save private key to file."""
        encryption = (
            serialization.BestAvailableEncryption(password)
            if password
            else serialization.NoEncryption()
        )
        
        pem_data = private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=encryption,
        )
        
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "wb") as f:
            f.write(pem_data)
        
        # Set restrictive permissions
        os.chmod(path, 0o600)


class MTLSContext:
    """Creates SSL contexts for mTLS connections."""
    
    def __init__(self, config: MTLSConfig, cert_manager: CertificateManager):
        self.config = config
        self.cert_manager = cert_manager
        self._ssl_context: Optional[ssl.SSLContext] = None
        
    def create_ssl_context(self) -> ssl.SSLContext:
        """Create SSL context for mTLS."""
        # Determine minimum protocol version
        if self.config.min_protocol_version == "TLSv1.3":
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.minimum_version = ssl.TLSVersion.TLSv1_3
        else:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
        
        # Load client certificate and key
        if os.path.exists(self.config.cert_path) and os.path.exists(self.config.key_path):
            context.load_cert_chain(
                certfile=self.config.cert_path,
                keyfile=self.config.key_path,
            )
        
        # Load CA bundle for server verification
        if os.path.exists(self.config.ca_bundle_path):
            context.load_verify_locations(cafile=self.config.ca_bundle_path)
        else:
            # Use system CA certificates
            context.load_default_certs()
        
        # Set verification mode
        context.verify_mode = ssl.CERT_REQUIRED
        context.check_hostname = self.config.verify_hostname
        
        # Set cipher suites (TLS 1.2)
        if self.config.cipher_suites:
            try:
                cipher_string = ":".join(self.config.cipher_suites)
                context.set_ciphers(cipher_string)
            except ssl.SSLError:
                # Fall back to default ciphers
                logger.warning("Failed to set custom cipher suites, using defaults")
        
        return context
    
    def get_ssl_context(self) -> ssl.SSLContext:
        """Get or create SSL context."""
        if self._ssl_context is None:
            self._ssl_context = self.create_ssl_context()
        return self._ssl_context
    
    def refresh_ssl_context(self):
        """Refresh SSL context (e.g., after certificate rotation)."""
        self._ssl_context = self.create_ssl_context()


class MTLSClient:
    """HTTP client with mTLS support."""
    
    def __init__(self, config: MTLSConfig):
        self.config = config
        self.cert_manager = CertificateManager(config)
        self.mtls_context = MTLSContext(config, self.cert_manager)
        self._client: Optional[httpx.AsyncClient] = None
        
    async def get_client(self) -> httpx.AsyncClient:
        """Get or create async HTTP client with mTLS."""
        if self._client is None:
            if self.config.enabled:
                ssl_context = self.mtls_context.get_ssl_context()
                self._client = httpx.AsyncClient(verify=ssl_context)
            else:
                self._client = httpx.AsyncClient(verify=True)
        return self._client
    
    async def request(
        self,
        method: str,
        url: str,
        **kwargs
    ) -> httpx.Response:
        """Make HTTP request with mTLS."""
        client = await self.get_client()
        return await client.request(method, url, **kwargs)
    
    async def get(self, url: str, **kwargs) -> httpx.Response:
        """Make GET request."""
        return await self.request("GET", url, **kwargs)
    
    async def post(self, url: str, **kwargs) -> httpx.Response:
        """Make POST request."""
        return await self.request("POST", url, **kwargs)
    
    async def close(self):
        """Close client connection."""
        if self._client:
            await self._client.aclose()
            self._client = None
    
    def get_client_certificate_info(self) -> Optional[CertificateInfo]:
        """Get information about the client certificate."""
        if not os.path.exists(self.config.cert_path):
            return None
        
        cert = self.cert_manager.load_certificate(self.config.cert_path)
        return self.cert_manager.get_certificate_info(cert)
    
    def check_certificate_health(self) -> Dict[str, Any]:
        """Check health of client certificate."""
        if not os.path.exists(self.config.cert_path):
            return {
                "status": "missing",
                "message": "Client certificate not found",
                "path": self.config.cert_path,
            }
        
        cert = self.cert_manager.load_certificate(self.config.cert_path)
        status, message = self.cert_manager.validate_certificate(cert)
        needs_rotation, rotation_message = self.cert_manager.check_rotation_needed(cert)
        info = self.cert_manager.get_certificate_info(cert)
        
        return {
            "status": status.value,
            "message": message,
            "rotation_needed": needs_rotation,
            "rotation_message": rotation_message,
            "certificate": info.to_dict(),
        }


# Singleton instance
_mtls_client: Optional[MTLSClient] = None


def get_mtls_client() -> MTLSClient:
    """Get or create mTLS client singleton."""
    global _mtls_client
    if _mtls_client is None:
        config = MTLSConfig.from_env()
        _mtls_client = MTLSClient(config)
    return _mtls_client


def get_mtls_config() -> MTLSConfig:
    """Get mTLS configuration from environment."""
    return MTLSConfig.from_env()


async def create_mtls_http_client() -> httpx.AsyncClient:
    """Create HTTP client with mTLS for backend connections."""
    client = get_mtls_client()
    return await client.get_client()