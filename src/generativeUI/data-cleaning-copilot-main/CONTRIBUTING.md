# Contributing to Data Cleaning Copilot

Thank you for your interest in contributing to the Data Cleaning Copilot project! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Making Changes](#making-changes)
- [Commit Guidelines](#commit-guidelines)
- [Pull Request Process](#pull-request-process)
- [Testing](#testing)
- [Documentation](#documentation)
- [Security](#security)

## Code of Conduct

This project adheres to the [SAP Open Source Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior to the project maintainers.

## Getting Started

### Prerequisites

- Python 3.10 or higher
- Node.js 18+ (for MCP server development)
- Git
- Docker (optional, for containerized testing)

### Fork and Clone

1. Fork the repository on GitHub
2. Clone your fork locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/data-cleaning-copilot.git
   cd data-cleaning-copilot
   ```
3. Add the upstream remote:
   ```bash
   git remote add upstream https://github.com/SAP/data-cleaning-copilot.git
   ```

## Development Setup

### Python Environment

```bash
# Create virtual environment
python -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate

# Install dependencies
pip install -e ".[dev]"

# Verify installation
python -c "from definition.base.executable_code import CheckLogic; print('OK')"
```

### MCP Server (Node.js)

```bash
cd mcp_server
npm install
npm run build
```

### Environment Configuration

```bash
# Copy example configuration
cp .env.example .env

# Edit with your settings (SAP AI Core credentials, etc.)
# For development, most settings can use defaults
```

### Running Tests

```bash
# Run all tests
pytest

# Run with coverage
pytest --cov=definition --cov-report=html

# Run specific test file
pytest tests/test_mcp_server_integration.py -v

# Run load tests (requires running MCP server)
python tests/load_test.py --target http://localhost:9110/mcp --duration 30
```

## Making Changes

### Branch Naming

Use descriptive branch names:

- `feature/add-new-tool` - New features
- `fix/sandbox-timeout-issue` - Bug fixes
- `docs/update-api-reference` - Documentation
- `refactor/agent-base-class` - Code refactoring
- `test/add-e2e-tests` - Test additions

### Code Style

This project uses:

- **Black** for Python code formatting
- **Ruff** for Python linting
- **mypy** for type checking
- **Prettier** for YAML/JSON/Markdown formatting

Run formatters before committing:

```bash
# Format Python code
black definition/ tests/ mcp_server/

# Lint Python code
ruff check definition/ tests/

# Type check
mypy definition/
```

### Adding New Features

1. **Discuss first**: For significant changes, open an issue to discuss the approach
2. **Write tests**: All new features should include tests
3. **Update docs**: Update relevant documentation
4. **Add changelog entry**: Add to CHANGELOG.md under [Unreleased]

### Adding New MCP Tools

When adding a new MCP tool:

1. Add handler method in `mcp_server/server.py`:
   ```python
   def _handle_new_tool(self, params: Dict[str, Any]) -> Dict[str, Any]:
       # Validate required parameters
       required_param = params.get("required_param")
       if not required_param:
           return {"error": "required_param is required"}
       
       # Implement tool logic
       result = do_something(required_param)
       
       # Track invocation for audit
       self._track_tool_invocation("new_tool", {"param": required_param})
       
       return {"status": "success", "result": result}
   ```

2. Register the tool in `__init__`:
   ```python
   self.tools["new_tool"] = {
       "name": "new_tool",
       "description": "Description of what the tool does",
       "inputSchema": {
           "type": "object",
           "properties": {
               "required_param": {
                   "type": "string",
                   "description": "Parameter description"
               }
           },
           "required": ["required_param"]
       }
   }
   ```

3. Add tests in `tests/test_mcp_server_integration.py`
4. Update `docs/API.md` with tool documentation
5. Update `docs/openapi.yaml` if applicable
6. Add Mangle rules if the tool requires governance

## Commit Guidelines

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

### Types

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Code style (formatting, etc.)
- `refactor`: Code refactoring
- `test`: Adding tests
- `chore`: Maintenance tasks
- `perf`: Performance improvements
- `ci`: CI/CD changes
- `security`: Security improvements

### Scopes

- `agent`: Agent-related changes
- `mcp`: MCP server changes
- `sandbox`: Sandbox execution
- `auth`: Authentication
- `observability`: Metrics/tracing/logging
- `docs`: Documentation

### Examples

```
feat(mcp): add new data_profiling tool

Implements statistical profiling for table columns including:
- Null count and percentage
- Unique value count
- Min/max/mean for numeric columns
- Sample values

Closes #123
```

```
fix(sandbox): increase default timeout to 30 seconds

Some complex validation checks were timing out at 10 seconds.
Increased default to 30 seconds and made configurable via
SANDBOX_TIMEOUT environment variable.

Fixes #456
```

## Pull Request Process

### Before Submitting

1. **Rebase on main**: Ensure your branch is up to date
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

2. **Run all checks**:
   ```bash
   black --check definition/ tests/
   ruff check definition/ tests/
   mypy definition/
   pytest
   ```

3. **Update documentation**: Ensure docs reflect your changes

4. **Add changelog entry**: Add to [Unreleased] section

### PR Template

When opening a PR, include:

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
How were these changes tested?

## Checklist
- [ ] Code follows project style guidelines
- [ ] Tests added/updated
- [ ] Documentation updated
- [ ] CHANGELOG.md updated
- [ ] No new security vulnerabilities introduced
```

### Review Process

1. At least one maintainer must approve
2. All CI checks must pass
3. No merge conflicts
4. Squash commits if requested

## Testing

### Test Categories

| Category | Location | Purpose |
|----------|----------|---------|
| Unit | `tests/test_*.py` | Individual function testing |
| Integration | `tests/test_*_integration.py` | Component interaction |
| E2E | `tests/test_e2e_*.py` | Full workflow testing |
| Load | `tests/load_test.py` | Performance testing |

### Writing Tests

```python
# tests/test_example.py
import unittest
from definition.base.executable_code import CheckLogic


class TestCheckLogic(unittest.TestCase):
    """Test CheckLogic class."""

    def test_to_code_generates_valid_python(self):
        """Verify generated code is syntactically valid."""
        check = CheckLogic(
            function_name="test_check",
            description="Test check",
            parameters="tables: Mapping[str, pd.DataFrame]",
            scope=[("TestTable", "TestColumn")],
            body_lines=["violations = {}"],
            return_statement="violations",
        )
        
        code = check.to_code()
        
        # Should parse without syntax errors
        import ast
        ast.parse(code)  # Raises SyntaxError if invalid
```

### Test Data

Use the mock database fixtures in `tests/test_agent_workflow_integration.py`:

```python
from tests.test_agent_workflow_integration import MockDatabase

def test_with_mock_database():
    db = MockDatabase("test_db")
    db.add_table("Users", pd.DataFrame({
        "Id": [1, 2, 3],
        "Name": ["Alice", "Bob", None],
    }))
    # Test against db
```

## Documentation

### Documentation Structure

```
docs/
├── API.md           # API reference
├── DEPLOYMENT.md    # Deployment guide
└── openapi.yaml     # OpenAPI specification
```

### Updating Documentation

- **API changes**: Update `docs/API.md` and `docs/openapi.yaml`
- **New features**: Add usage examples to relevant docs
- **Configuration**: Update `.env.example` with new variables

### Docstrings

Use Google-style docstrings:

```python
def validate_table(table_name: str, checks: List[str] = None) -> Dict[str, Any]:
    """
    Validate a table against registered checks.

    Parameters
    ----------
    table_name : str
        Name of the table to validate
    checks : List[str], optional
        Specific checks to run. If None, runs all applicable checks.

    Returns
    -------
    Dict[str, Any]
        Validation results including violations and summary

    Raises
    ------
    ValueError
        If table_name is not found in database

    Example
    -------
    >>> results = validate_table("Users", checks=["check_users_name_not_null"])
    >>> print(results["summary"]["total_violations"])
    3
    """
```

## Security

### Reporting Vulnerabilities

**Do not report security vulnerabilities through public GitHub issues.**

Instead, please report them via SAP's security reporting process or contact the maintainers directly.

### Security Considerations

When contributing:

1. **Sandbox code**: Never execute LLM-generated code outside the sandbox
2. **Input validation**: Always validate and sanitize inputs
3. **Authentication**: Never bypass authentication in production code
4. **Secrets**: Never commit secrets, tokens, or credentials
5. **Dependencies**: Keep dependencies updated, check for CVEs

### SPDX Headers

All source files must include SPDX license headers:

```python
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
```

## Questions?

- Open a GitHub issue for bugs or feature requests
- Tag maintainers for urgent questions
- Check existing issues before creating new ones

Thank you for contributing!