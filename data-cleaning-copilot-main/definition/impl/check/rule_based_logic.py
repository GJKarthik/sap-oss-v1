"""Rule-based logic generation for validation and corruption."""

from typing import Type, List, Dict, Optional, Mapping
from definition.base.table import Table
from definition.base.executable_code import CheckLogic, CorruptionLogic
from definition.impl.check.constants import FK_CHECK_DESCRIPTION
from definition.base.corruption import corruption_from_validation_func
import pandas as pd
from loguru import logger


def create_foreign_key_check(
    child_table_name: str, child_fk_column: str, parent_table_name: str, parent_column: str
) -> CheckLogic:
    """Create a CheckLogic for foreign key validation."""
    scope = [(child_table_name, child_fk_column), (parent_table_name, parent_column)]

    # Using f-strings to embed variables in the function body
    body_lines = [
        f"    child_table = tables.get('{child_table_name}', pd.DataFrame())",
        f"    parent_table = tables.get('{parent_table_name}', pd.DataFrame())",
        "    violations = {}",
        f"    if child_table.empty or '{child_fk_column}' not in child_table.columns:",
        "        return violations",
        f"    if parent_table.empty or '{parent_column}' not in parent_table.columns:",
        "        valid_values = set()",
        "    else:",
        f"        valid_values = set(parent_table['{parent_column}'].dropna())",
        f"    child_fk_series = child_table['{child_fk_column}']",
        "    non_null_mask = child_fk_series.notna()",
        "    child_fk_values = child_fk_series[non_null_mask]",
        "    invalid_mask = ~child_fk_values.isin(valid_values)",
        "    if invalid_mask.any():",
        "        offending_values = child_fk_values[invalid_mask]",
        f"        violations['{child_table_name}'] = pd.Series(",
        f"            offending_values.values, index=offending_values.index, name='{child_fk_column}'",
        "        )",
    ]

    return CheckLogic(
        function_name=f"fk_check_{child_table_name}_{child_fk_column}_{parent_table_name}_{parent_column}",
        description=FK_CHECK_DESCRIPTION.format(
            child_table=child_table_name,
            child_column=child_fk_column,
            parent_table=parent_table_name,
            parent_column=parent_column,
        ),
        scope=scope,
        imports=["import pandas as pd"],
        parameters="tables",
        body_lines=body_lines,
        return_statement="violations",
        sql=f"SELECT c.* FROM {child_table_name} c LEFT JOIN {parent_table_name} p ON c.{child_fk_column} = p.{parent_column} WHERE p.{parent_column} IS NULL AND c.{child_fk_column} IS NOT NULL",
    )


def execute_llm_checks(table_data: Mapping[str, pd.DataFrame], llm_checks: Dict[str, CheckLogic]) -> pd.DataFrame:
    """Execute LLM-generated checks and return violations DataFrame."""
    frames = []
    for check_name, check in llm_checks.items():
        try:
            validation_fn = check.to_validation_function()
            validation_result = validation_fn(table_data)
            violations = corruption_from_validation_func(
                validation_result=validation_result, check_name=check_name, table_data=table_data
            )
            if not violations.empty:
                frames.append(violations)
        except Exception as e:
            logger.warning(f"LLM Check '{check_name}' failed: {e}")
            continue

    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()


def create_foreign_key_corruption(
    child_table_name: str, child_column: str, parent_table_name: str, parent_column: str
) -> CorruptionLogic:
    """Create a CorruptionLogic for foreign key corruption."""
    scope = [(child_table_name, child_column), (parent_table_name, parent_column)]

    body_lines = [
        "    corrupted_data = {k: v.copy() for k, v in table_data.items()}",
        f"    if '{child_table_name}' not in corrupted_data or '{parent_table_name}' not in table_data:",
        "        return corrupted_data",
        f"    child_df = corrupted_data['{child_table_name}']",
        f"    parent_df = table_data['{parent_table_name}']",
        f"    if '{child_column}' not in child_df.columns or '{parent_column}' not in parent_df.columns:",
        "        return corrupted_data",
        "    if percentage <= 0:",
        "        return corrupted_data",
        f"    valid_parent_values = set(parent_df['{parent_column}'].dropna())",
        f"    child_fk_values = child_df['{child_column}']",
        "    non_null_indices = child_fk_values.dropna().index",
        "    if len(non_null_indices) == 0:",
        "        return corrupted_data",
        "    num_to_corrupt = int(len(non_null_indices) * percentage)",
        "    if num_to_corrupt == 0:",
        "        return corrupted_data",
        "    indices_to_corrupt = rand.sample(list(non_null_indices), min(num_to_corrupt, len(non_null_indices)))",
        "    for idx in indices_to_corrupt:",
        f"        current_value = child_df.at[idx, '{child_column}']",
        "        if pd.api.types.is_numeric_dtype(type(current_value)):",
        "            max_val = max(valid_parent_values) if valid_parent_values else 999999",
        f"            child_df.at[idx, '{child_column}'] = max_val + rand.randint(1, 1000)",
        "        else:",
        f"            child_df.at[idx, '{child_column}'] = f'INVALID_FK_{{rand.randint(1000, 9999)}}'",
        f"    corrupted_data['{child_table_name}'] = child_df",
    ]

    return CorruptionLogic(
        function_name=f"fk_corrupt_{child_table_name}_{child_column}_{parent_table_name}_{parent_column}",
        description=f"Corrupts foreign key {child_table_name}.{child_column} -> {parent_table_name}.{parent_column}",
        scope=scope,
        imports=["import pandas as pd"],
        parameters="table_data, rand, percentage",
        body_lines=body_lines,
        return_statement="corrupted_data",
        sql=f"UPDATE {child_table_name} SET {child_column} = INVALID_VALUE WHERE {child_column} IS NOT NULL",
    )


def create_numerical_corruption(
    table_name: str, column_name: str, min_val: Optional[float], max_val: Optional[float]
) -> CorruptionLogic:
    """Create a CorruptionLogic for numerical bounds corruption."""
    scope = [(table_name, column_name)]

    body_lines = [
        "    corrupted_data = {k: v.copy() for k, v in table_data.items()}",
        f"    if '{table_name}' not in corrupted_data:",
        "        return corrupted_data",
        f"    df = corrupted_data['{table_name}']",
        f"    if '{column_name}' not in df.columns:",
        "        return corrupted_data",
        "    if percentage <= 0:",
        "        return corrupted_data",
        f"    column_data = df['{column_name}']",
        "    valid_indices = column_data.dropna().index",
        "    if len(valid_indices) == 0:",
        "        return corrupted_data",
        "    num_to_corrupt = int(len(valid_indices) * percentage)",
        "    if num_to_corrupt == 0:",
        "        return corrupted_data",
        "    indices_to_corrupt = rand.sample(list(valid_indices), min(num_to_corrupt, len(valid_indices)))",
        "    for idx in indices_to_corrupt:",
    ]

    if min_val is not None and max_val is not None:
        body_lines.extend(
            [
                "        if rand.random() < 0.5:",
                f"            df.at[idx, '{column_name}'] = {min_val} - rand.uniform(1, 100)",
                "        else:",
                f"            df.at[idx, '{column_name}'] = {max_val} + rand.uniform(1, 100)",
            ]
        )
    elif min_val is not None:
        body_lines.extend([f"        df.at[idx, '{column_name}'] = {min_val} - rand.uniform(1, 100)"])
    elif max_val is not None:
        body_lines.extend([f"        df.at[idx, '{column_name}'] = {max_val} + rand.uniform(1, 100)"])

    body_lines.append(f"    corrupted_data['{table_name}'] = df")

    return CorruptionLogic(
        function_name=f"numerical_corrupt_{table_name}_{column_name}",
        description=f"Corrupts {table_name}.{column_name} by violating numerical bounds",
        scope=scope,
        imports=["import pandas as pd"],
        parameters="table_data, rand, percentage",
        body_lines=body_lines,
        return_statement="corrupted_data",
        sql="",
    )


def create_pattern_corruption(table_name: str, column_name: str, pattern: str) -> CorruptionLogic:
    """Create a CorruptionLogic for pattern/regex corruption."""
    scope = [(table_name, column_name)]

    return CorruptionLogic(
        function_name=f"pattern_corrupt_{table_name}_{column_name}",
        description=f"Corrupts {table_name}.{column_name} by violating regex pattern",
        scope=scope,
        imports=["import pandas as pd", "import string"],
        parameters="table_data, rand, percentage",
        body_lines=[
            "    corrupted_data = {k: v.copy() for k, v in table_data.items()}",
            f"    if '{table_name}' not in corrupted_data:",
            "        return corrupted_data",
            f"    df = corrupted_data['{table_name}']",
            f"    if '{column_name}' not in df.columns:",
            "        return corrupted_data",
            "    if percentage <= 0:",
            "        return corrupted_data",
            f"    column_data = df['{column_name}']",
            "    valid_indices = column_data.dropna().index",
            "    if len(valid_indices) == 0:",
            "        return corrupted_data",
            "    num_to_corrupt = int(len(valid_indices) * percentage)",
            "    if num_to_corrupt == 0:",
            "        return corrupted_data",
            "    indices_to_corrupt = rand.sample(list(valid_indices), min(num_to_corrupt, len(valid_indices)))",
            "    for idx in indices_to_corrupt:",
            f"        current_value = str(df.at[idx, '{column_name}'])",
            "        corruption_type = rand.choice(['remove_char', 'add_space', 'duplicate_special', 'replace_with_invalid'])",
            "        if corruption_type == 'remove_char' and len(current_value) > 1:",
            "            pos = rand.randint(0, len(current_value) - 1)",
            "            corrupted_value = current_value[:pos] + current_value[pos+1:]",
            "        elif corruption_type == 'add_space':",
            "            pos = rand.randint(0, len(current_value))",
            "            corrupted_value = current_value[:pos] + ' ' + current_value[pos:]",
            "        elif corruption_type == 'duplicate_special':",
            "            special_chars = '@._-'",
            "            chars_in_value = [c for c in special_chars if c in current_value]",
            "            if chars_in_value:",
            "                char_to_dup = rand.choice(chars_in_value)",
            "                pos = current_value.find(char_to_dup)",
            "                corrupted_value = current_value[:pos] + char_to_dup + current_value[pos:]",
            "            else:",
            "                corrupted_value = current_value + '@@'",
            "        else:",
            "            corrupted_value = 'INVALID_' + str(rand.randint(1000, 9999))",
            f"        df.at[idx, '{column_name}'] = corrupted_value",
            f"    corrupted_data['{table_name}'] = df",
        ],
        return_statement="corrupted_data",
        sql="",
    )


def create_nullifier_corruption(table_name: str, column_name: str) -> CorruptionLogic:
    """Create a CorruptionLogic for NULL corruption."""
    scope = [(table_name, column_name)]

    return CorruptionLogic(
        function_name=f"null_corrupt_{table_name}_{column_name}",
        description=f"Corrupts {table_name}.{column_name} by inserting NULL values",
        scope=scope,
        imports=["import pandas as pd", "import numpy as np"],
        parameters="table_data, rand, percentage",
        body_lines=[
            "    corrupted_data = {k: v.copy() for k, v in table_data.items()}",
            f"    if '{table_name}' not in corrupted_data:",
            "        return corrupted_data",
            f"    df = corrupted_data['{table_name}']",
            f"    if '{column_name}' not in df.columns:",
            "        return corrupted_data",
            "    if percentage <= 0:",
            "        return corrupted_data",
            f"    column_data = df['{column_name}']",
            "    valid_indices = column_data.dropna().index",
            "    if len(valid_indices) == 0:",
            "        return corrupted_data",
            "    num_to_corrupt = int(len(valid_indices) * percentage)",
            "    if num_to_corrupt == 0:",
            "        return corrupted_data",
            "    indices_to_corrupt = rand.sample(list(valid_indices), min(num_to_corrupt, len(valid_indices)))",
            "    for idx in indices_to_corrupt:",
            f"        df.at[idx, '{column_name}'] = np.nan",
            f"    corrupted_data['{table_name}'] = df",
        ],
        return_statement="corrupted_data",
        sql="",
    )


def create_comparison_corruption(table_name: str, column1: str, column2: str, operator: str) -> CorruptionLogic:
    """Create a CorruptionLogic for comparison constraint corruption."""
    scope = [(table_name, column1), (table_name, column2)]

    # Generate corruption lines based on operator
    if operator == "<=":
        corruption_lines = [
            f"        new_val = df.at[idx, '{column2}'] + rand.uniform(1, 100)",
            f"        orig_dtype = df['{column1}'].dtype",
            f"        if pd.api.types.is_integer_dtype(orig_dtype):",
            f"            df.at[idx, '{column1}'] = int(new_val)",
            f"        else:",
            f"            df.at[idx, '{column1}'] = new_val",
        ]
    elif operator == ">=":
        corruption_lines = [
            f"        new_val = df.at[idx, '{column2}'] - rand.uniform(1, 100)",
            f"        orig_dtype = df['{column1}'].dtype",
            f"        if pd.api.types.is_integer_dtype(orig_dtype):",
            f"            df.at[idx, '{column1}'] = int(new_val)",
            f"        else:",
            f"            df.at[idx, '{column1}'] = new_val",
        ]
    elif operator == "<":
        corruption_lines = [
            f"        new_val = df.at[idx, '{column2}'] + rand.uniform(0.1, 100)",
            f"        orig_dtype = df['{column1}'].dtype",
            f"        if pd.api.types.is_integer_dtype(orig_dtype):",
            f"            df.at[idx, '{column1}'] = int(new_val)",
            f"        else:",
            f"            df.at[idx, '{column1}'] = new_val",
        ]
    elif operator == ">":
        corruption_lines = [
            f"        new_val = df.at[idx, '{column2}'] - rand.uniform(0.1, 100)",
            f"        orig_dtype = df['{column1}'].dtype",
            f"        if pd.api.types.is_integer_dtype(orig_dtype):",
            f"            df.at[idx, '{column1}'] = int(new_val)",
            f"        else:",
            f"            df.at[idx, '{column1}'] = new_val",
        ]
    else:
        corruption_lines = [
            f"        new_val = df.at[idx, '{column2}'] + rand.uniform(1, 100)",
            f"        orig_dtype = df['{column1}'].dtype",
            f"        if pd.api.types.is_integer_dtype(orig_dtype):",
            f"            df.at[idx, '{column1}'] = int(new_val)",
            f"        else:",
            f"            df.at[idx, '{column1}'] = new_val",
        ]

    body_lines = (
        [
            "    corrupted_data = {k: v.copy() for k, v in table_data.items()}",
            f"    if '{table_name}' not in corrupted_data:",
            "        return corrupted_data",
            f"    df = corrupted_data['{table_name}']",
            f"    if '{column1}' not in df.columns or '{column2}' not in df.columns:",
            "        return corrupted_data",
            "    if percentage <= 0:",
            "        return corrupted_data",
            f"    valid_indices = df[['{column1}', '{column2}']].dropna().index",
            "    if len(valid_indices) == 0:",
            "        return corrupted_data",
            "    num_to_corrupt = int(len(valid_indices) * percentage)",
            "    if num_to_corrupt == 0:",
            "        return corrupted_data",
            "    indices_to_corrupt = rand.sample(list(valid_indices), min(num_to_corrupt, len(valid_indices)))",
            "    for idx in indices_to_corrupt:",
        ]
        + corruption_lines
        + [f"    corrupted_data['{table_name}'] = df"]
    )

    return CorruptionLogic(
        function_name=f"comparison_corrupt_{table_name}_{column1}_{column2}",
        description=f"Corrupts {table_name} by violating {column1} {operator} {column2}",
        scope=scope,
        imports=["import pandas as pd"],
        parameters="table_data, rand, percentage",
        body_lines=body_lines,
        return_statement="corrupted_data",
        sql="",
    )


def create_pandera_check_placeholder(table_name: str, check_name: str, column_name: Optional[str] = None) -> CheckLogic:
    """
    Create a placeholder CheckLogic for pandera validation checks.
    These checks are executed directly by pandera, so the logic is empty.

    Parameters
    ----------
    table_name : str
        Name of the table
    check_name : str
        Name of the check (should already include table and column prefixes if applicable)
    column_name : Optional[str]
        If provided, sets the scope to this specific column. Otherwise scope covers all columns.
    """
    # Set scope based on whether this is a column-level or table-level check
    if column_name:
        scope = [(table_name, column_name)]
        description = f"Pandera validation check: {check_name} for column {table_name}.{column_name}"
    else:
        scope = [(table_name, "*")]  # Table-level check
        description = f"Pandera validation check: {check_name} for table {table_name}"

    return CheckLogic(
        function_name=check_name,  # Use the full check name as function name
        description=description,
        scope=scope,
        imports=[],
        parameters="tables",
        body_lines=["    return {}"],  # Empty logic since pandera handles validation
        return_statement="{}",
        sql="",
    )


def get_corruptors_from_pandera(table_name: str, table_cls: Type[Table]) -> List[CorruptionLogic]:
    """Generate CorruptionLogic instances from pandera field constraints."""
    import inspect
    import re

    corruptors = []
    columns = table_cls.columns()

    # Collect numerical bounds
    numerical_bounds = {}
    regex_patterns = {}
    nullable_columns = []

    for col_name, col_schema in columns.items():
        checks = getattr(col_schema, "checks", [])

        for check in checks:
            stats = getattr(check, "statistics", {})

            # Handle numerical constraints
            min_val = None
            max_val = None

            if "min_value" in stats:
                min_val = stats["min_value"]
            if "max_value" in stats:
                max_val = stats["max_value"]
            if "gt" in stats:
                min_val = stats["gt"]
            if "lt" in stats:
                max_val = stats["lt"]

            if min_val is not None or max_val is not None:
                if min_val is not None and max_val is not None and min_val == max_val:
                    continue
                numerical_bounds[col_name] = (min_val, max_val)

            # Handle regex constraints
            if "pattern" in stats:
                regex_patterns[col_name] = stats["pattern"]
            elif hasattr(check, "pattern"):
                pattern = getattr(check, "pattern", None)
                if pattern:
                    regex_patterns[col_name] = pattern

            # Handle nullable constraints
            check_name = getattr(check, "__class__", type(check)).__name__
            if "notnull" in check_name.lower() or hasattr(check, "nullable"):
                nullable = getattr(check, "nullable", True)
                if not nullable:
                    nullable_columns.append(col_name)

    # Create numerical corruptors
    for col_name, bounds in numerical_bounds.items():
        if col_name in columns:
            col_dtype = columns[col_name].dtype.type
            if pd.api.types.is_numeric_dtype(col_dtype):
                corruptor = create_numerical_corruption(
                    table_name=table_name, column_name=col_name, min_val=bounds[0], max_val=bounds[1]
                )
                corruptors.append(corruptor)

    # Create pattern corruptors
    for col_name, pattern in regex_patterns.items():
        corruptor = create_pattern_corruption(table_name=table_name, column_name=col_name, pattern=pattern)
        corruptors.append(corruptor)

    # Create nullifier corruptors
    for col_name in nullable_columns:
        corruptor = create_nullifier_corruption(table_name=table_name, column_name=col_name)
        corruptors.append(corruptor)

    # Parse dataframe-level checks for comparison constraints
    schema = table_cls.to_schema()
    dataframe_checks = schema.checks if schema.checks is not None else []

    for check in dataframe_checks:
        try:
            check_name = getattr(check, "name", str(check))
            check_func = None

            for name, method in inspect.getmembers(
                table_cls, predicate=lambda x: inspect.isfunction(x) or inspect.ismethod(x)
            ):
                if name == check_name:
                    check_func = method
                    break

            if check_func and callable(check_func):
                try:
                    source = inspect.getsource(check_func)

                    if "<=" in source or ">=" in source or "<" in source or ">" in source or "==" in source:
                        pattern = r'df\["([^"]+)"\]\s*([<>=!]+)\s*df\["([^"]+)"\]'
                        matches = re.findall(pattern, source)

                        for match in matches:
                            column1, operator, column2 = match
                            if operator == "<=":
                                corruptor = create_comparison_corruption(
                                    table_name=table_name, column1=column1, column2=column2, operator=operator
                                )
                                corruptors.append(corruptor)
                except (OSError, TypeError):
                    pass
        except Exception:
            pass

    return corruptors
