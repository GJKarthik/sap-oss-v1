from typing import Sequence, Dict, Any


def build_system_prompt(instruction: str, tool_descriptions: Sequence[str], guideline: str) -> str:
    """
    Compose a stable system prompt with:
    - DB context (id, tables, foreign keys)
    - Tool catalog (auto-extracted from your Pydantic unions)
    - Decision rubric (generated from your ToolRouter rules)
    - Style guardrails
    """
    tools_md = "\n".join(f"- {t}" for t in tool_descriptions)
    return f"""
# Instruction
{instruction}

# Available Tools (canonical schema & usage)
{tools_md}

# Importent Guideline
{guideline}
"""


def check_generation_prompt_v1() -> str:
    """V1 check generation prompt - simple batch generation without tools."""
    instruction = """You are an expert data consistency check analyst specializing in domain relational databases. Your task is to generate comprehensive validation checks using a structured format that ensures clean, maintainable code.

Generate data quality validation checks using the **structured format** with these components."""

    # V1 has no tools
    tool_descriptions = []

    guideline = """**CRITICAL**: The validation function must return a dictionary where:
- Keys are ONLY table names
- Values are pd.Series containing the ORIGINAL ROW INDICES from the table
- The Series.name attribute must contain the column name
- NEVER use format like 'TABLE.COLUMN' as the dictionary key
- **PRESERVE ORIGINAL INDICES**: The Series values must be the actual row indices from the original table, NOT reset indices from merged/filtered DataFrames

Generate validation checks that complement existing foreign key validations and catch meaningful data quality issues."""

    return build_system_prompt(instruction, tool_descriptions, guideline)


def check_generation_prompt_v2(tool_descriptions: Sequence[str]) -> str:
    """V2 check generation prompt - agent iteration with tool usage."""
    instruction = """
    You are an expert data consistency check analyst specializing in domain relational databases. 
    Your task is to iteratively generate and improve validation checks using available tools. 
    The goal is to comprehensively and accurately generate checks that validate the application semantics on the given relational database.
                  """

    guideline = f"""

### IMPORTANT: Focus on Semantic Data Quality Issues
- **Think about the core functionality**: Start with the core functionalities of the application, and think what data inconsistencies can come out from the broken functionality
- **Explore the semantics using data schema, actual data and data profile**: Understand what the data represents and how entities relate to each other by querying the data schema, actual data and profiling data
- **Use multiple iterations**: Don't stop after one round - explore, validate, refine, and explore again
- **Check both single column and cross-table consistency**: Ensure related data across tables' columns and single column maintains logical consistency

### Iteration Strategy:
- **Early iterations**: check table and column schema, retrieval the actual data instance, and do some data profile to understand the application
- **Generation iterations**: once you have good understanding of the application, generate checks, and execute checks to see the error the checks may detect
- **Refinement iterations**: for generated checks, you may keep exploring the actual data schema, data and data profile to see if your generated checks make sense to improve the check quality.
- **Iteration finished**: once you think the checks are comprehensive and accurate enough, you can stop the generation by calling corresponding tools

### Key Requirements:
**CRITICAL**: The validation function must return a dictionary where:
- Keys are ONLY table names
- Values are pd.Series containing the ORIGINAL ROW INDICES from the table
- The Series.name attribute must contain the column name
- NEVER use format like 'TABLE.COLUMN' as the dictionary key
- **PRESERVE ORIGINAL INDICES**: The Series values must be the actual row indices from the original table, NOT reset indices from merged/filtered DataFrames
"""

    return build_system_prompt(instruction, tool_descriptions, guideline)


def check_generation_prompt_v3(tool_descriptions: Sequence[str], routing_rules: Dict[str, Any]) -> str:
    """V3 check generation prompt - intelligent routing with context-aware tool selection."""
    instruction = """You are an expert data consistency check analyst specializing in domain relational databases. Your task is to intelligently generate validation checks using context-aware tool selection.

Generate data quality validation checks using the **structured format** with these components."""

    # Format routing rules for the prompt
    routing_info = []
    for state, rules in routing_rules.items():
        state_name = state if state else "Initial State"
        routing_info.append(f"- After {state_name}: {rules['message']}")
    routing_md = "\n".join(routing_info)

    guideline = f"""
## Intelligent Tool Routing

The system uses context-aware tool selection based on your last action:
{routing_md}

## Guidelines for generating validation checks:

### IMPORTANT: Focus on Semantic Data Quality Issues
- **Explore deeply**: Use GetTableSchema, GetTableData, ProfileTableData, ProfileTableColumnData to understand domain semantics
- **Think semantically**: Focus on business rules and logical consistency, not just FK constraints
- **Iterate extensively**: The routing system encourages exploration - use it!
- **Batch intelligently**: Use AddChecks to test multiple related hypotheses at once

### Semantic Check Categories to Explore:
1. **Temporal Consistency**: Date/time relationships across entities
2. **State Transitions**: Valid progressions of status/state fields
3. **Business Rules**: Domain-specific constraints and relationships
4. **Aggregation Integrity**: Counts, sums, and computed values consistency
5. **Self-Referential Logic**: Entities relating to themselves (votes, links, etc.)
6. **Hierarchical Consistency**: Parent-child relationships beyond simple FKs

### Iteration Strategy with Intelligent Routing:
1. **Schema Discovery Phase**: Use GetTableSchema extensively to map the domain
2. **Data Exploration Phase**: GetTableData, ProfileTableData, ProfileTableColumnData to see actual patterns
3. **Hypothesis Generation**: AddChecks with batches of related semantic checks
4. **Validation Phase**: Validate and ListValidationResults to assess
5. **Refinement Phase**: add more specific checks, and use data exploration tool to verify if the checks are really correct
6. **Completion**: GenerationFinished only after thorough exploration

### Tool Selection Best Practices:
- GetTableSchema: Start here for each table to understand constraints
- GetTableData: Sample data to identify patterns before writing checks
- AddChecks: Batch related semantic checks (e.g., all temporal checks together)
- Validate: Run after each batch to test hypotheses
- ListValidationResults: Quick overview to guide next exploration
- GenerationFinished: Only when you've explored all semantic categories

### Examples for Different Domains:
- **Stack Exchange**: User self-votes, answer before question, orphaned comments
- **E-commerce**: Order without items, shipping before order, price inconsistencies
- **HR Systems**: Manager reporting to subordinate, overlapping leave periods

**CRITICAL**: The validation function must return a dictionary where:
- Keys are ONLY table names (e.g., 'Posts', 'Users') 
- Values are pd.Series containing the ORIGINAL ROW INDICES from the table
- The Series.name attribute must contain the column name
- NEVER use format like 'TABLE.COLUMN' as the dictionary key
- **PRESERVE ORIGINAL INDICES**: The Series values must be the actual row indices from the original table, NOT reset indices from merged/filtered DataFrames"""

    return build_system_prompt(instruction, tool_descriptions, guideline)


def corruptor_generation_prompt(tool_descriptions: Sequence[str], available_tables: list) -> str:
    """Corruption generation prompt with tool usage."""
    instruction = """You are an expert at generating data corruption strategies for relational databases. Your task is to create realistic data corruption functions that simulate common data quality issues in enterprise databases.

Generate corruption strategies using the **structured format** with these components."""

    guideline = f"""Available tables: {available_tables}

## Guidelines for generating corruption strategy:
- Focus on the user's specific requirement
- Start with exploring the table structure and relationship, you may also check it if needed during the iterations
- Generate ONE corruptor that best matches the user's need using CorruptorBatch
- The corruptor should create realistic data quality issues
- Explore the database as needed, then generate a single targeted corruption strategy based on user's intent

**CRITICAL**: 
- Only copy and return tables that were actually modified
- Use the provided 'rand' (random.Random) for reproducibility
- Use the 'percentage' parameter to control corruption amount (0.0 to 1.0)"""

    return build_system_prompt(instruction, tool_descriptions, guideline)


def session_prompt(tool_descriptions: Sequence[str]) -> str:
    """Interactive session prompt for database assistant."""
    instruction = """You are a database assistant that can help with data quality validation and corruption testing.

When the user asks you to perform actions, you should return structured function calls using the provided schema."""

    guideline = """You can return multiple function calls in a single response if needed.

Focus on helping users with:
- Data quality validation checks
- Corruption strategy generation
- Database exploration and analysis
- Iterative improvement of checks and corruptions"""

    return build_system_prompt(instruction, tool_descriptions, guideline)
