# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Unit tests for LLM router with PII-aware routing.

Tests cover:
- PII keyword detection
- PII pattern detection (SSN, credit card, email)
- Data classification based on context
- Routing decisions (vLLM vs AI Core)
- Backend availability handling
"""

import pytest
from unittest.mock import Mock, patch, MagicMock
import sys
import os

# Add parent to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from llm.router import (
    LLMBackend,
    LLMRouter,
    PII_KEYWORDS,
    PII_PATTERNS,
    ONPREM_REQUIRED_CLASSES,
    get_router,
    route_and_chat,
    check_pii,
)


class TestPIIKeywords:
    """Test PII keyword definitions."""
    
    def test_personal_identifiers_in_keywords(self):
        assert "customer" in PII_KEYWORDS
        assert "personal" in PII_KEYWORDS
        assert "ssn" in PII_KEYWORDS
        assert "social_security" in PII_KEYWORDS
    
    def test_financial_in_keywords(self):
        assert "credit_card" in PII_KEYWORDS
        assert "bank_account" in PII_KEYWORDS
        assert "salary" in PII_KEYWORDS
        assert "compensation" in PII_KEYWORDS
    
    def test_contact_info_in_keywords(self):
        assert "email" in PII_KEYWORDS
        assert "phone" in PII_KEYWORDS
        assert "address" in PII_KEYWORDS
    
    def test_identity_documents_in_keywords(self):
        assert "passport" in PII_KEYWORDS
        assert "driver_license" in PII_KEYWORDS
        assert "date_of_birth" in PII_KEYWORDS


class TestPIIPatterns:
    """Test PII regex pattern detection."""
    
    def test_ssn_pattern(self):
        ssn_pattern = PII_PATTERNS[0]  # SSN format
        assert ssn_pattern.search("123-45-6789")
        assert not ssn_pattern.search("12-345-6789")
        assert not ssn_pattern.search("1234567890")
    
    def test_credit_card_pattern(self):
        cc_pattern = PII_PATTERNS[1]  # Credit card format
        assert cc_pattern.search("4111-1111-1111-1111")
        assert cc_pattern.search("4111111111111111")
        assert cc_pattern.search("4111 1111 1111 1111")
        assert not cc_pattern.search("411111111111")  # Too short
    
    def test_email_pattern(self):
        email_pattern = PII_PATTERNS[2]  # Email format
        assert email_pattern.search("test@example.com")
        assert email_pattern.search("user.name+tag@domain.co.uk")
        assert not email_pattern.search("not-an-email")


class TestLLMBackend:
    """Test LLM backend class."""
    
    def test_backend_creation(self):
        backend = LLMBackend("test", "http://localhost:8080", "onprem")
        assert backend.name == "test"
        assert backend.url == "http://localhost:8080"
        assert backend.backend_type == "onprem"
        assert backend._healthy is True
    
    def test_backend_url_normalization(self):
        backend = LLMBackend("test", "http://localhost:8080/", "cloud")
        assert backend.url == "http://localhost:8080"  # Trailing slash removed
    
    def test_backend_availability(self):
        backend = LLMBackend("test", "http://localhost:8080", "onprem")
        assert backend.is_available() is True
        
        backend.mark_unhealthy()
        assert backend.is_available() is False
        
        backend.mark_healthy()
        assert backend.is_available() is True


class TestLLMRouter:
    """Test LLM router class."""
    
    @pytest.fixture
    def router(self):
        """Create router instance."""
        return LLMRouter()
    
    def test_router_has_backends(self, router):
        assert router.aicore is not None
        assert router.vllm is not None
        assert router.ollama is not None
    
    def test_contains_pii_with_keywords(self, router):
        has_pii, indicators = router.contains_pii("Check customer data")
        assert has_pii is True
        assert "keyword:customer" in indicators
    
    def test_contains_pii_with_ssn(self, router):
        has_pii, indicators = router.contains_pii("SSN is 123-45-6789")
        assert has_pii is True
        assert "keyword:ssn" in indicators
        assert "pattern:0" in indicators  # SSN pattern
    
    def test_contains_pii_with_email(self, router):
        has_pii, indicators = router.contains_pii("Contact user@example.com")
        assert has_pii is True
        assert "keyword:email" in indicators or "pattern:2" in indicators
    
    def test_contains_pii_with_credit_card(self, router):
        has_pii, indicators = router.contains_pii("Card: 4111-1111-1111-1111")
        assert has_pii is True
        assert "pattern:1" in indicators  # Credit card pattern
    
    def test_no_pii_detected(self, router):
        has_pii, indicators = router.contains_pii("Show product catalog")
        assert has_pii is False
        assert len(indicators) == 0
    
    def test_empty_text(self, router):
        has_pii, indicators = router.contains_pii("")
        assert has_pii is False
        assert len(indicators) == 0
    
    def test_none_text(self, router):
        has_pii, indicators = router.contains_pii(None)
        assert has_pii is False


class TestDataClassification:
    """Test data classification based on context."""
    
    @pytest.fixture
    def router(self):
        return LLMRouter()
    
    def test_explicit_classification(self, router):
        assert router.classify_data({"data_class": "confidential"}) == "confidential"
        assert router.classify_data({"data_class": "PUBLIC"}) == "public"
        assert router.classify_data({"data_class": "restricted"}) == "restricted"
    
    def test_classification_from_table_name(self, router):
        assert router.classify_data({"table_name": "Customers"}) == "confidential"
        assert router.classify_data({"table_name": "EMPLOYEE_DATA"}) == "confidential"
        assert router.classify_data({"table_name": "user_profiles"}) == "confidential"
    
    def test_classification_from_financial_table(self, router):
        assert router.classify_data({"table_name": "Transactions"}) == "confidential"
        assert router.classify_data({"table_name": "salary_data"}) == "confidential"
        assert router.classify_data({"table_name": "Payments"}) == "confidential"
    
    def test_classification_from_schema_columns(self, router):
        context = {
            "schema": {
                "columns": [
                    {"name": "id"},
                    {"name": "email"},
                    {"name": "created_at"},
                ]
            }
        }
        assert router.classify_data(context) == "confidential"
    
    def test_default_classification(self, router):
        assert router.classify_data({}) == "internal"
        assert router.classify_data({"table_name": "Products"}) == "internal"


class TestRouteRequest:
    """Test routing decision logic."""
    
    @pytest.fixture
    def router(self):
        router = LLMRouter()
        router.enforce_pii_routing = True
        return router
    
    def test_route_pii_to_vllm(self, router):
        backend, meta = router.route_request("Show customer email addresses")
        
        assert backend.name == "vllm"
        assert meta["contains_pii"] is True
        assert meta["routing_reason"] == "pii_detected"
    
    def test_route_confidential_to_vllm(self, router):
        backend, meta = router.route_request(
            "Show data",
            context={"data_class": "confidential"}
        )
        
        assert backend.name == "vllm"
        assert meta["routing_reason"] == "data_class_confidential"
    
    def test_route_restricted_to_vllm(self, router):
        backend, meta = router.route_request(
            "Show data",
            context={"data_class": "restricted"}
        )
        
        assert backend.name == "vllm"
        assert meta["routing_reason"] == "data_class_restricted"
    
    def test_route_public_to_aicore(self, router):
        backend, meta = router.route_request("Show product catalog")
        
        assert backend.name == "aicore"
        assert meta["routing_reason"] == "default"
    
    def test_route_with_messages(self, router):
        messages = [
            {"role": "user", "content": "Show customer data"},
        ]
        backend, meta = router.route_request("", messages=messages)
        
        assert backend.name == "vllm"
        assert meta["contains_pii"] is True
    
    def test_routing_disabled(self, router):
        router.enforce_pii_routing = False
        backend, meta = router.route_request("Show customer SSN 123-45-6789")
        
        # Should route to default (aicore) when enforcement disabled
        assert backend.name == "aicore"
        assert meta["routing_reason"] == "default"
        # But still detects PII for metadata
        assert meta["contains_pii"] is True


class TestBackendCalls:
    """Test backend call methods."""
    
    @pytest.fixture
    def router(self):
        return LLMRouter()
    
    def test_call_vllm_success(self, router):
        mock_response = {
            "choices": [
                {"message": {"content": "Hello!"}}
            ]
        }
        
        with patch('urllib.request.urlopen') as mock_urlopen:
            mock_resp = MagicMock()
            mock_resp.read.return_value = '{"choices":[{"message":{"content":"Hello!"}}]}'.encode()
            mock_resp.__enter__ = Mock(return_value=mock_resp)
            mock_resp.__exit__ = Mock(return_value=False)
            mock_urlopen.return_value = mock_resp
            
            result = router.call_vllm([{"role": "user", "content": "Hi"}])
            
            assert result["content"] == "Hello!"
            assert result["backend"] == "vllm"
    
    def test_call_vllm_failure(self, router):
        with patch('urllib.request.urlopen') as mock_urlopen:
            mock_urlopen.side_effect = Exception("Connection refused")
            
            result = router.call_vllm([{"role": "user", "content": "Hi"}])
            
            assert result["content"] == ""
            assert "error" in result
            assert router.vllm.is_available() is False


class TestHighLevelChat:
    """Test high-level chat method."""
    
    @pytest.fixture
    def router(self):
        return LLMRouter()
    
    def test_chat_with_pii_routes_to_vllm(self, router):
        messages = [{"role": "user", "content": "Show customer emails"}]
        
        with patch.object(router, 'call_vllm') as mock_vllm:
            mock_vllm.return_value = {"content": "Here are the emails", "backend": "vllm"}
            
            result = router.chat(messages)
            
            mock_vllm.assert_called_once()
            assert result["routing"]["backend"] == "vllm"
    
    def test_chat_without_pii_routes_to_aicore(self, router):
        messages = [{"role": "user", "content": "Show products"}]
        
        with patch.object(router, 'call_aicore') as mock_aicore:
            mock_aicore.return_value = {"content": "Here are products", "backend": "aicore"}
            
            result = router.chat(messages)
            
            mock_aicore.assert_called_once()
            assert result["routing"]["backend"] == "aicore"


class TestConvenienceFunctions:
    """Test module-level convenience functions."""
    
    def test_get_router_singleton(self):
        import llm.router as router_module
        router_module._router = None
        
        router1 = get_router()
        router2 = get_router()
        
        assert router1 is router2
    
    def test_check_pii_function(self):
        result = check_pii("Customer email: test@example.com")
        
        assert result["contains_pii"] is True
        assert result["recommended_backend"] == "vllm"
        assert len(result["indicators"]) > 0
    
    def test_check_pii_no_pii(self):
        result = check_pii("Show product catalog")
        
        assert result["contains_pii"] is False
        assert result["recommended_backend"] == "aicore"
    
    def test_route_and_chat_function(self):
        with patch('llm.router.get_router') as mock_get_router:
            mock_router = MagicMock()
            mock_router.chat.return_value = {
                "content": "Response",
                "routing": {"backend": "vllm"}
            }
            mock_get_router.return_value = mock_router
            
            result = route_and_chat([{"role": "user", "content": "Hi"}])
            
            mock_router.chat.assert_called_once()
            assert result["content"] == "Response"


class TestOnpremRequiredClasses:
    """Test on-premise required classifications."""
    
    def test_confidential_requires_onprem(self):
        assert "confidential" in ONPREM_REQUIRED_CLASSES
    
    def test_restricted_requires_onprem(self):
        assert "restricted" in ONPREM_REQUIRED_CLASSES
    
    def test_pii_requires_onprem(self):
        assert "pii" in ONPREM_REQUIRED_CLASSES
    
    def test_public_not_requires_onprem(self):
        assert "public" not in ONPREM_REQUIRED_CLASSES
    
    def test_internal_not_requires_onprem(self):
        assert "internal" not in ONPREM_REQUIRED_CLASSES


class TestEdgeCases:
    """Test edge cases and error handling."""
    
    def test_case_insensitive_pii_detection(self):
        router = LLMRouter()
        
        has_pii1, _ = router.contains_pii("CUSTOMER data")
        has_pii2, _ = router.contains_pii("Customer data")
        has_pii3, _ = router.contains_pii("customer data")
        
        assert has_pii1 is True
        assert has_pii2 is True
        assert has_pii3 is True
    
    def test_pii_in_table_name_context(self):
        router = LLMRouter()
        
        context = {"table_name": "CustomerEmails"}
        data_class = router.classify_data(context)
        
        assert data_class == "confidential"
    
    def test_multiple_pii_indicators(self):
        router = LLMRouter()
        
        text = "Customer SSN 123-45-6789 email test@example.com"
        has_pii, indicators = router.contains_pii(text)
        
        assert has_pii is True
        assert len(indicators) >= 3  # customer, ssn, pattern:0, pattern:2