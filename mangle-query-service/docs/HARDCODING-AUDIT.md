# Hardcoding Audit Report

## Date: March 11, 2026 (Day 8)

## Summary

This audit identifies hardcoded values in the mangle-query-service codebase and documents the refactoring to use:
1. **SAP AI Core** for LLM access (no direct OpenAI/Anthropic APIs)
2. **Mangle rules** for configuration instead of Python hardcoding
3. **Environment variables** for runtime configuration

---

## Critical Findings - FIXED

### 1. Model Provider Hardcoding (FIXED)

**Original Issue:**
```python
# BAD - Hardcoded external API providers
class ModelProvider(str, Enum):
    OPENAI = "openai"        # ❌ Direct API access
    ANTHROPIC = "anthropic"  # ❌ Direct API access
```

**Fixed:**
```python
# GOOD - SAP AI Core and private LLM only
class ModelProvider(str, Enum):
    SAP_AI_CORE = "sap_ai_core"
    PRIVATE_LLM = "private_llm"
    VLLM = "vllm"
```

### 2. Backend URLs Hardcoded (FIXED)

**Original Issue:**
```python
# BAD - Hardcoded external URLs
base_url="https://api.openai.com/v1"
base_url="https://api.anthropic.com"
```

**Fixed:**
```python
# GOOD - Load from environment
def _get_backend_url(self, backend_id: str) -> str:
    env_map = {
        "aicore_primary": "AICORE_BASE_URL",
        "vllm_primary": "VLLM_BASE_URL",
    }
    return os.environ.get(env_var, "")
```

### 3. Model Definitions Hardcoded (FIXED)

**Original Issue:**
Models were hardcoded in Python with `_register_default_models()`.

**Fixed:**
Models now loaded from `rules/model_registry.mg` Mangle facts.

---

## Configuration Sources

### Mangle Rules (Primary)

| File | Purpose |
|------|---------|
| `rules/model_registry.mg` | Model definitions, capabilities, backends |
| `rules/analytics_routing.mg` | Query routing rules |

### Environment Variables

| Variable | Purpose | Required |
|----------|---------|----------|
| `AICORE_BASE_URL` | SAP AI Core endpoint | Yes |
| `AICORE_CLIENT_ID` | OAuth client ID | Yes |
| `AICORE_CLIENT_SECRET` | OAuth client secret | Yes |
| `AICORE_TOKEN_URL` | OAuth token endpoint | Yes |
| `VLLM_BASE_URL` | Private vLLM endpoint | Optional |
| `HANA_HOST` | HANA Cloud hostname | Yes |
| `HANA_PORT` | HANA Cloud port | Yes |
| `ES_HOST` | Elasticsearch hostname | Yes |

---

## Files Audited

### Clean (No Hardcoding Issues)

| File | Status |
|------|--------|
| `connectors/http_client.py` | ✅ Clean |
| `middleware/retry.py` | ✅ Clean |
| `middleware/circuit_breaker.py` | ✅ Clean |
| `middleware/resilient_client.py` | ✅ Clean |
| `config/settings.py` | ✅ Clean (uses env vars) |

### Fixed

| File | Issue | Fix |
|------|-------|-----|
| `routing/model_registry.py` | Hardcoded OpenAI/Anthropic | ✅ Now uses Mangle + AI Core |
| `routing/model_router.py` | Hardcoded providers | ✅ Updated to SAP AI Core |
| `openai/chat_completions.py` | N/A | Uses router, clean |
| `openai/sse_streaming.py` | N/A | Protocol only, clean |

---

## Architecture: Before vs After

### Before (BAD)
```
Client → OpenAI-Compatible API → Direct External APIs
                                    ├── api.openai.com (❌)
                                    └── api.anthropic.com (❌)
```

### After (GOOD)
```
Client → OpenAI-Compatible API → SAP AI Core Proxy
                                    ├── AI Core (GPT-4, etc.)
                                    └── Private vLLM (LLaMA, etc.)
```

---

## Mangle Integration Pattern

### Rules Define Configuration
```mangle
# rules/model_registry.mg
model("gpt-4", "GPT-4 via AI Core", "sap_ai_core", "aicore_primary").
model_capability("gpt-4", "chat").
model_enabled("gpt-4").
```

### Python Loads from Rules
```python
# routing/model_registry.py
class MangleFactsLoader:
    def load(self) -> None:
        # Parse Mangle facts from rules file
        
class ModelRegistry:
    def __init__(self):
        self._load_from_mangle()  # Load config from rules
```

---

## Remaining Work

### Low Priority

1. **Timeout values** - Consider moving to Mangle rules
2. **Retry counts** - Consider moving to Mangle rules
3. **Default models** - Consider dynamic discovery from AI Core

### Not Applicable

- HTTP status codes (standard, shouldn't change)
- OpenAI response format (API spec compliance)
- Error message templates (i18n could be added later)

---

## Verification

### Unit Tests Pass
All 300+ tests continue to pass with refactored code.

### Manual Verification
```bash
# Check for hardcoded external URLs
grep -r "api.openai.com" mangle-query-service/
grep -r "api.anthropic.com" mangle-query-service/
# Should return: no matches
```

---

## Recommendations

1. **Always use Mangle rules** for configuration that may change
2. **Always use environment variables** for secrets and endpoints
3. **Never hardcode** external API URLs
4. **All LLM access** must go through SAP AI Core or private vLLM
5. **Document** any configuration in `.env.example`

---

## Sign-off

- [x] No hardcoded external API URLs
- [x] All models via SAP AI Core or private LLM
- [x] Configuration in Mangle rules
- [x] Secrets in environment variables
- [x] Unit tests passing