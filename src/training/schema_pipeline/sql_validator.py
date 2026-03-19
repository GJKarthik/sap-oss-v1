"""
sql_validator.py

SAP HANA SQL syntax validator for text-to-SQL training data.
Validates generated SQL queries against HANA-specific syntax rules.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any
from enum import Enum


class ValidationSeverity(Enum):
    ERROR = "error"
    WARNING = "warning"
    INFO = "info"


@dataclass
class ValidationResult:
    """Result of SQL validation."""
    is_valid: bool
    severity: ValidationSeverity
    message: str
    line: int = 0
    column: int = 0
    suggestion: str = ""


@dataclass
class ValidationReport:
    """Complete validation report for a SQL query."""
    sql: str
    is_valid: bool
    errors: list[ValidationResult] = field(default_factory=list)
    warnings: list[ValidationResult] = field(default_factory=list)
    
    @property
    def error_count(self) -> int:
        return len(self.errors)
    
    @property
    def warning_count(self) -> int:
        return len(self.warnings)


class HANASQLValidator:
    """
    Validates SQL syntax for SAP HANA compatibility.
    
    Checks for:
    - HANA-incompatible functions
    - Reserved word usage
    - Identifier quoting requirements
    - JOIN syntax correctness
    - Subquery structure
    """
    
    # Functions that need HANA-specific syntax
    INCOMPATIBLE_FUNCTIONS = {
        r'\bYEAR\s*\(': ('YEAR()', 'Use EXTRACT(YEAR FROM column) instead'),
        r'\bMONTH\s*\(': ('MONTH()', 'Use EXTRACT(MONTH FROM column) instead'),
        r'\bDAY\s*\(': ('DAY()', 'Use EXTRACT(DAY FROM column) instead'),
        r'\bQUARTER\s*\(': ('QUARTER()', 'Use CEIL(EXTRACT(MONTH FROM column) / 3.0) instead'),
        r'\bDATEDIFF\s*\(': ('DATEDIFF()', 'Use DAYS_BETWEEN() or SECONDS_BETWEEN() instead'),
        r'\bDATE_ADD\s*\(': ('DATE_ADD()', 'Use ADD_DAYS(), ADD_MONTHS() instead'),
        r'\bDATE_SUB\s*\(': ('DATE_SUB()', 'Use ADD_DAYS(column, -n) instead'),
        r'\bNOW\s*\(': ('NOW()', 'Use CURRENT_TIMESTAMP instead'),
        r'\bCURDATE\s*\(': ('CURDATE()', 'Use CURRENT_DATE instead'),
        r'\bIFNULL\s*\(': ('IFNULL()', 'Use COALESCE() instead for portability'),
        r'\bIF\s*\(': ('IF()', 'Use CASE WHEN ... THEN ... ELSE ... END instead'),
        r'\bGROUP_CONCAT\s*\(': ('GROUP_CONCAT()', 'Use STRING_AGG() instead'),
        r'\bCONCAT_WS\s*\(': ('CONCAT_WS()', 'Use || operator with COALESCE() instead'),
    }
    
    # HANA reserved words that need quoting
    RESERVED_WORDS = {
        'YEAR', 'MONTH', 'DAY', 'HOUR', 'MINUTE', 'SECOND',
        'DATE', 'TIME', 'TIMESTAMP', 'INTERVAL',
        'ORDER', 'GROUP', 'SELECT', 'FROM', 'WHERE', 'JOIN',
        'LEFT', 'RIGHT', 'INNER', 'OUTER', 'FULL', 'CROSS',
        'INDEX', 'KEY', 'PRIMARY', 'FOREIGN', 'UNIQUE',
        'TABLE', 'VIEW', 'SCHEMA', 'DATABASE',
        'USER', 'ROLE', 'GRANT', 'REVOKE',
        'LIMIT', 'OFFSET', 'FETCH', 'FIRST', 'NEXT', 'ONLY',
        'WINDOW', 'OVER', 'PARTITION', 'ROWS', 'RANGE',
        'CURRENT', 'PRECEDING', 'FOLLOWING', 'UNBOUNDED',
    }
    
    # Valid HANA aggregate functions
    VALID_AGGREGATES = {
        'SUM', 'AVG', 'COUNT', 'MIN', 'MAX',
        'STDDEV', 'STDDEV_POP', 'STDDEV_SAMP',
        'VAR', 'VAR_POP', 'VAR_SAMP', 'VARIANCE',
        'MEDIAN', 'PERCENTILE_CONT', 'PERCENTILE_DISC',
        'STRING_AGG', 'CORR', 'COVAR_POP', 'COVAR_SAMP',
        'FIRST_VALUE', 'LAST_VALUE', 'NTH_VALUE',
    }
    
    # Valid HANA window functions
    VALID_WINDOW_FUNCTIONS = {
        'ROW_NUMBER', 'RANK', 'DENSE_RANK', 'NTILE',
        'LEAD', 'LAG', 'FIRST_VALUE', 'LAST_VALUE', 'NTH_VALUE',
        'CUME_DIST', 'PERCENT_RANK',
    }
    
    def __init__(self, strict: bool = False):
        """
        Initialize validator.
        
        Args:
            strict: If True, warnings become errors
        """
        self.strict = strict
    
    def validate(self, sql: str) -> ValidationReport:
        """
        Validate a SQL query for HANA compatibility.
        
        Args:
            sql: SQL query string
            
        Returns:
            ValidationReport with errors and warnings
        """
        errors = []
        warnings = []
        
        # Check for incompatible functions
        for pattern, (func_name, suggestion) in self.INCOMPATIBLE_FUNCTIONS.items():
            if re.search(pattern, sql, re.IGNORECASE):
                result = ValidationResult(
                    is_valid=False,
                    severity=ValidationSeverity.ERROR,
                    message=f"Incompatible function: {func_name}",
                    suggestion=suggestion,
                )
                errors.append(result)
        
        # Check for unquoted reserved words as identifiers
        warnings.extend(self._check_reserved_words(sql))
        
        # Check for proper JOIN syntax
        errors.extend(self._check_join_syntax(sql))
        
        # Check for balanced parentheses
        if not self._check_balanced_parens(sql):
            errors.append(ValidationResult(
                is_valid=False,
                severity=ValidationSeverity.ERROR,
                message="Unbalanced parentheses",
            ))
        
        # Check for proper OVER clause in window functions
        warnings.extend(self._check_window_functions(sql))
        
        # Check for proper LIMIT syntax (HANA uses LIMIT or TOP)
        warnings.extend(self._check_limit_syntax(sql))
        
        # Check for CTE syntax
        warnings.extend(self._check_cte_syntax(sql))
        
        # Promote warnings to errors in strict mode
        if self.strict:
            errors.extend(warnings)
            warnings = []
        
        is_valid = len(errors) == 0
        
        return ValidationReport(
            sql=sql,
            is_valid=is_valid,
            errors=errors,
            warnings=warnings,
        )
    
    def _check_reserved_words(self, sql: str) -> list[ValidationResult]:
        """Check for unquoted reserved words used as column aliases."""
        warnings = []
        
        # Look for AS <reserved_word> without quotes
        alias_pattern = r'\bAS\s+([A-Za-z_][A-Za-z0-9_]*)\b'
        for match in re.finditer(alias_pattern, sql, re.IGNORECASE):
            alias = match.group(1).upper()
            if alias in self.RESERVED_WORDS:
                warnings.append(ValidationResult(
                    is_valid=True,
                    severity=ValidationSeverity.WARNING,
                    message=f"Reserved word '{alias}' used as alias",
                    suggestion=f'Quote the alias: AS "{alias}"',
                ))
        
        return warnings
    
    def _check_join_syntax(self, sql: str) -> list[ValidationResult]:
        """Check for proper JOIN syntax."""
        errors = []
        
        # Check for JOIN without ON clause
        join_pattern = r'\b(LEFT|RIGHT|INNER|FULL|CROSS)?\s*JOIN\s+[^\s]+\s+[^\s]+(?!\s+ON\b)'
        
        # Simplified check: ensure JOINs have ON clauses
        join_count = len(re.findall(r'\bJOIN\b', sql, re.IGNORECASE))
        on_count = len(re.findall(r'\bON\b', sql, re.IGNORECASE))
        cross_join_count = len(re.findall(r'\bCROSS\s+JOIN\b', sql, re.IGNORECASE))
        
        # CROSS JOINs don't need ON clauses
        expected_on = join_count - cross_join_count
        
        if on_count < expected_on:
            errors.append(ValidationResult(
                is_valid=False,
                severity=ValidationSeverity.ERROR,
                message=f"JOIN without ON clause detected ({on_count} ON for {join_count} JOINs)",
                suggestion="Add ON clause to specify join condition",
            ))
        
        return errors
    
    def _check_balanced_parens(self, sql: str) -> bool:
        """Check for balanced parentheses."""
        count = 0
        for char in sql:
            if char == '(':
                count += 1
            elif char == ')':
                count -= 1
            if count < 0:
                return False
        return count == 0
    
    def _check_window_functions(self, sql: str) -> list[ValidationResult]:
        """Check for proper window function usage."""
        warnings = []
        
        # Check for window functions without OVER clause
        for func in self.VALID_WINDOW_FUNCTIONS:
            pattern = rf'\b{func}\s*\([^)]*\)(?!\s+OVER\b)'
            if re.search(pattern, sql, re.IGNORECASE):
                # Double-check it's not followed by OVER
                if f'{func}(' in sql.upper() and 'OVER' not in sql.upper().split(f'{func}(')[1].split(')')[0]:
                    warnings.append(ValidationResult(
                        is_valid=True,
                        severity=ValidationSeverity.WARNING,
                        message=f"Window function {func}() may need OVER clause",
                        suggestion=f"Add OVER (PARTITION BY ... ORDER BY ...)",
                    ))
        
        return warnings
    
    def _check_limit_syntax(self, sql: str) -> list[ValidationResult]:
        """Check for proper LIMIT syntax."""
        warnings = []
        
        # HANA supports LIMIT but recommends TOP for performance
        if re.search(r'\bLIMIT\s+\d+\s+OFFSET\s+\d+', sql, re.IGNORECASE):
            warnings.append(ValidationResult(
                is_valid=True,
                severity=ValidationSeverity.INFO,
                message="LIMIT ... OFFSET syntax detected",
                suggestion="Consider using LIMIT with OFFSET for better readability",
            ))
        
        return warnings
    
    def _check_cte_syntax(self, sql: str) -> list[ValidationResult]:
        """Check for proper CTE (WITH clause) syntax."""
        warnings = []
        
        if sql.strip().upper().startswith('WITH'):
            # Check for AS ( pattern after CTE name
            if not re.search(r'\bWITH\s+\w+\s+AS\s*\(', sql, re.IGNORECASE):
                warnings.append(ValidationResult(
                    is_valid=True,
                    severity=ValidationSeverity.WARNING,
                    message="CTE may have incorrect syntax",
                    suggestion="Use: WITH cte_name AS (SELECT ...)",
                ))
        
        return warnings


def validate_training_data(train_file: str, output_file: str | None = None) -> dict[str, Any]:
    """
    Validate all SQL queries in a training data file.
    
    Args:
        train_file: Path to training JSON file
        output_file: Optional path to write validation report
        
    Returns:
        Summary statistics
    """
    import json
    from pathlib import Path
    
    with open(train_file) as f:
        data = json.load(f)
    
    validator = HANASQLValidator(strict=False)
    
    total = len(data)
    valid = 0
    invalid = 0
    with_warnings = 0
    
    errors_by_type: dict[str, int] = {}
    invalid_queries: list[dict] = []
    
    for item in data:
        sql = item.get('query', '')
        report = validator.validate(sql)
        
        if report.is_valid:
            valid += 1
            if report.warning_count > 0:
                with_warnings += 1
        else:
            invalid += 1
            invalid_queries.append({
                'id': item.get('id', 'unknown'),
                'question': item.get('question', ''),
                'query': sql,
                'errors': [e.message for e in report.errors],
            })
            for error in report.errors:
                errors_by_type[error.message] = errors_by_type.get(error.message, 0) + 1
    
    summary = {
        'total': total,
        'valid': valid,
        'invalid': invalid,
        'with_warnings': with_warnings,
        'validity_rate': round(100 * valid / total, 2) if total > 0 else 0,
        'errors_by_type': errors_by_type,
    }
    
    if output_file:
        report_data = {
            'summary': summary,
            'invalid_queries': invalid_queries[:100],  # Limit to 100 examples
        }
        with open(output_file, 'w') as f:
            json.dump(report_data, f, indent=2)
    
    return summary


# CLI interface
if __name__ == '__main__':
    import sys
    import json
    
    if len(sys.argv) < 2:
        print("Usage: python sql_validator.py <train.json> [output_report.json]")
        sys.exit(1)
    
    train_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else None
    
    print(f"Validating SQL queries in {train_file}...")
    summary = validate_training_data(train_file, output_file)
    
    print(f"\nValidation Summary:")
    print(f"  Total queries: {summary['total']}")
    print(f"  Valid: {summary['valid']} ({summary['validity_rate']}%)")
    print(f"  Invalid: {summary['invalid']}")
    print(f"  With warnings: {summary['with_warnings']}")
    
    if summary['errors_by_type']:
        print(f"\nErrors by type:")
        for error_type, count in sorted(summary['errors_by_type'].items(), key=lambda x: -x[1]):
            print(f"  - {error_type}: {count}")
    
    if output_file:
        print(f"\nDetailed report written to: {output_file}")