"""
Pytest Configuration and Fixtures

Shared fixtures for OData Vocabularies tests.
"""

import pytest
import sys
import os
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))


@pytest.fixture(scope="session")
def vocab_dir():
    """Path to vocabularies directory"""
    return Path(__file__).parent.parent / "vocabularies"


@pytest.fixture(scope="session")
def test_vocabularies(vocab_dir):
    """Load vocabularies for testing"""
    from xml.etree import ElementTree as ET
    
    vocabularies = {}
    for xml_file in vocab_dir.glob("*.xml"):
        try:
            tree = ET.parse(xml_file)
            root = tree.getroot()
            
            # Extract namespace
            ns = {"edmx": "http://docs.oasis-open.org/odata/ns/edmx",
                  "edm": "http://docs.oasis-open.org/odata/ns/edm"}
            
            schema = root.find(".//edm:Schema", ns)
            if schema is not None:
                namespace = schema.get("Namespace", "")
                alias = schema.get("Alias", namespace.split(".")[-1])
                vocabularies[alias] = {
                    "namespace": namespace,
                    "file": xml_file.name,
                    "terms": [],
                    "complex_types": [],
                    "enum_types": []
                }
                
                for term in schema.findall("edm:Term", ns):
                    vocabularies[alias]["terms"].append(term.get("Name"))
                
                for ct in schema.findall("edm:ComplexType", ns):
                    vocabularies[alias]["complex_types"].append(ct.get("Name"))
                
                for et in schema.findall("edm:EnumType", ns):
                    vocabularies[alias]["enum_types"].append(et.get("Name"))
                    
        except Exception as e:
            print(f"Warning: Could not parse {xml_file}: {e}")
    
    return vocabularies


@pytest.fixture
def sample_entity():
    """Sample entity for testing generators"""
    return {
        "name": "SalesOrder",
        "properties": [
            {"name": "SalesOrderID", "type": "Edm.String", "nullable": False, "isKey": True},
            {"name": "CustomerID", "type": "Edm.String", "nullable": False},
            {"name": "CustomerName", "type": "Edm.String", "nullable": True},
            {"name": "CustomerEmail", "type": "Edm.String", "nullable": True},
            {"name": "TotalAmount", "type": "Edm.Decimal", "nullable": True},
            {"name": "OrderDate", "type": "Edm.Date", "nullable": True},
            {"name": "Status", "type": "Edm.String", "nullable": True}
        ]
    }


@pytest.fixture
def sample_query():
    """Sample natural language query"""
    return "Show me all customers with their email addresses and order totals"


@pytest.fixture
def personal_data_samples():
    """Sample fields for personal data classification"""
    return [
        # Definitely personal
        {"name": "CustomerEmail", "type": "Edm.String", "expected": True, "sensitive": False},
        {"name": "PhoneNumber", "type": "Edm.String", "expected": True, "sensitive": False},
        {"name": "HomeAddress", "type": "Edm.String", "expected": True, "sensitive": False},
        {"name": "FullName", "type": "Edm.String", "expected": True, "sensitive": False},
        {"name": "DateOfBirth", "type": "Edm.Date", "expected": True, "sensitive": False},
        
        # Sensitive personal data
        {"name": "HealthStatus", "type": "Edm.String", "expected": True, "sensitive": True},
        {"name": "EthnicOrigin", "type": "Edm.String", "expected": True, "sensitive": True},
        {"name": "ReligiousAffiliation", "type": "Edm.String", "expected": True, "sensitive": True},
        
        # Not personal
        {"name": "ProductID", "type": "Edm.String", "expected": False, "sensitive": False},
        {"name": "OrderTotal", "type": "Edm.Decimal", "expected": False, "sensitive": False},
        {"name": "CreatedAt", "type": "Edm.DateTimeOffset", "expected": False, "sensitive": False}
    ]


@pytest.fixture
def mock_embeddings():
    """Mock embeddings for testing semantic search"""
    import random
    
    def generate_embedding(text: str, dim: int = 1536):
        """Generate deterministic mock embedding based on text hash"""
        random.seed(hash(text))
        return [random.uniform(-1, 1) for _ in range(dim)]
    
    return generate_embedding


@pytest.fixture
def auth_config():
    """Mock auth configuration"""
    from config.settings import AuthConfig
    return AuthConfig(
        enabled=True,
        api_keys=["test-api-key-12345"],
        jwt_secret="test-jwt-secret-at-least-32-characters",
        jwt_algorithm="HS256",
        jwt_expiry_hours=24,
        rate_limit_enabled=True,
        rate_limit_requests=10,
        rate_limit_window_seconds=60
    )