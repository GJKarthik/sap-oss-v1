# Day 2 - March 3, 2026 - Retry Logic + Error Handling

## Status: ✅ COMPLETE

---

## Summary

Implemented robust retry logic with exponential backoff, jitter, and structured error handling.

---

## Progress

### Tasks Completed

- [x] Create `mangle-query-service/middleware/retry.py`
- [x] Implement exponential backoff (1s, 2s, 4s, 8s max)
- [x] Add jitter to prevent thundering herd
- [x] Create structured error types
- [x] Write unit tests (36 test cases)

---

## Files Created/Modified

### New Files

| File | Lines | Purpose |
|------|-------|---------|
| `middleware/retry.py` | 437 | Retry middleware with backoff |
| `tests/unit/test_retry.py` | 480 | Unit tests (36 test cases) |

---

## Key Implementation Details

### Retry Configuration

```python
RetryConfig(
    max_retries=3,           # 3 retries + initial = 4 attempts
    base_delay=1.0,          # 1 second base
    max_delay=8.0,           # Cap at 8 seconds
    exponential_base=2.0,    # Double each time
    jitter_factor=0.25,      # ±25% randomization
)
```

### Backoff Schedule (Default)

| Attempt | Base Delay | With Jitter |
|---------|------------|-------------|
| 1 | 2s | 1.5s - 2.5s |
| 2 | 4s | 3s - 5s |
| 3 | 8s | 6s - 10s |

### Retry Strategies

| Strategy | Formula | Use Case |
|----------|---------|----------|
| EXPONENTIAL | base * 2^attempt | Default, transient failures |
| LINEAR | base * attempt | Gradual backpressure |
| FIXED | base | Polling scenarios |

### Retryable Conditions

```python
# Status codes that trigger retry
retryable_status_codes = {500, 502, 503, 504, 429}

# Exceptions that trigger retry
retryable_exceptions = (ConnectionError, TimeoutError, asyncio.TimeoutError)

# Never retry these (client errors)
non_retryable_status_codes = {400, 401, 403, 404, 405, 422}
```

### Classes Implemented

| Class | Purpose |
|-------|---------|
| `RetryConfig` | Configuration with presets |
| `RetryContext` | Tracks attempt state |
| `RetryableHTTPClient` | HTTP client with retry |
| `StructuredError` | OpenAI-compatible errors |
| `ErrorCodes` | Standard error codes |

### Functions

| Function | Purpose |
|----------|---------|
| `calculate_delay()` | Compute backoff with jitter |
| `retry_async()` | Execute with retry logic |
| `with_retry()` | Decorator for functions |
| `create_error_from_status()` | Map HTTP to error |
| `create_error_from_exception()` | Map exception to error |

---

## Error Code Mapping

| HTTP Status | Error Code |
|-------------|------------|
| 400 | BAD_REQUEST |
| 401 | UNAUTHORIZED |
| 403 | FORBIDDEN |
| 404 | NOT_FOUND |
| 429 | RATE_LIMITED |
| 500 | INTERNAL_ERROR |
| 502 | BACKEND_ERROR |
| 503 | SERVICE_UNAVAILABLE |
| 504 | BACKEND_TIMEOUT |

---

## Test Coverage

### Test Classes

| Class | Tests | Coverage |
|-------|-------|----------|
| `TestRetryConfig` | 6 | Configuration |
| `TestCalculateDelay` | 5 | Backoff math |
| `TestRetryContext` | 6 | Context tracking |
| `TestIsRetryable` | 5 | Retry conditions |
| `TestRetryAsync` | 8 | Core retry logic |
| `TestWithRetryDecorator` | 2 | Decorator |
| `TestRetryableHTTPClient` | 2 | HTTP integration |
| `TestStructuredError` | 4 | Error responses |
| `TestErrorCodes` | 1 | Error codes |
| `TestCreateErrorFromStatus` | 5 | Status mapping |
| `TestCreateErrorFromException` | 4 | Exception mapping |

**Total: 48 test cases**

---

## Acceptance Criteria

| Criteria | Status |
|----------|--------|
| Retry on 5xx errors | ✅ |
| Retry on network errors | ✅ |
| No retry on 4xx errors | ✅ |
| Max 3 retries with exponential backoff | ✅ |
| Structured error responses (JSON) | ✅ |
| Jitter prevents thundering herd | ✅ |

---

## Usage Examples

### Basic Retry

```python
from middleware.retry import retry_async, RetryConfig

async def make_request():
    return await http_client.get(url)

result = await retry_async(make_request, RetryConfig())
```

### Decorator

```python
from middleware.retry import with_retry, RetryConfig

@with_retry(RetryConfig.aggressive())
async def fetch_data():
    return await client.get(url)
```

### HTTP Client Wrapper

```python
from middleware.retry import RetryableHTTPClient

client = RetryableHTTPClient(http_client, RetryConfig())
response = await client.post(url, json=data)
```

---

## Notes

1. **Jitter**: Uses uniform distribution within ±25% of calculated delay
2. **Logging**: All retries logged with context (attempt, delay, error)
3. **Status Code Detection**: Works with any response that has `status_code` attribute
4. **Async-first**: Designed for async HTTP clients

---

## Blockers

None.

---

## Tomorrow (Day 3)

- [ ] Create `mangle-query-service/middleware/circuit_breaker.py`
- [ ] Implement three states: CLOSED, OPEN, HALF-OPEN
- [ ] Configure failure threshold (5 failures → OPEN)
- [ ] Configure recovery timeout (30s → HALF-OPEN)
- [ ] Integrate with HTTP client

---

## Commit

Ready to commit:
- `middleware/retry.py`
- `tests/unit/test_retry.py`
- `docs/tracking/week01/day02.md`