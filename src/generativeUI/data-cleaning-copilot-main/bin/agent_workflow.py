#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Automated agent workflow for check generation, validation, and evaluation."""

import os
import sys
import argparse
from pathlib import Path
from typing import Optional
from loguru import logger
from dotenv import load_dotenv
import pandas as pd
import uuid

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from definition.impl.database.rel_stack import RelStack
from definition.llm.session_manager import LLMSessionManager
from definition.llm.models import LLMProvider, LLMSessionConfig
from definition.agents import CheckGenerationAgentV1, CheckGenerationAgentV2

# ================== CONFIGURATION ==================
# Database-specific configurations
DATABASE_CONFIGS = {
    "rel_stack": {
        "class": RelStack,
        "base_id": "rel_stack_agent",
        "data_dir": "data/benchmark/rel_stack_4_corruptors/corrupted_data",
        "ground_truth": "data/benchmark/rel_stack_4_corruptors/corrupted_data/violations.csv",
        "result_dir": "data/benchmark/rel_stack_4_corruptors/result",
        "overall_file": "data/benchmark/rel_stack_4_corruptors/result/OVERALL.csv",
        "user_message": "This is Stack Exchange Q&A platform data. For some column with date, the detailed time(hour-minutes-seconds) is omitted for privacy reason.",
    },
}

# Fixed Model Parameters
TEMPERATURE = 0.1
MAX_TOKENS = 8000

# Default Logging Level
LOG_LEVEL = "DEBUG"  # Set to "DEBUG" for verbose logging

# ================== END CONFIGURATION ==================


def setup_logging(level: str = "INFO", log_file: Optional[str] = None):
    """Configure logging settings."""
    logger.remove()
    logger.add(sys.stderr, level=level)
    if log_file:
        logger.add(log_file, level=level, rotation="10 MB", retention="7 days")


def create_llm_configs(model, deployment_id):
    """Create LLM session configurations."""
    # Prompts are now handled by prompt_builder inside Database class
    # No need to load prompts here - they'll be generated based on version

    # Create configurations
    check_config = LLMSessionConfig(
        model_name=model,
        temperature=TEMPERATURE,
        max_tokens=MAX_TOKENS,
        deployment_id=deployment_id,
        system_message="",  # Will be set by Database based on version
        base_url=os.getenv("AICORE_BASE_URL"),
        auth_url=os.getenv("AICORE_AUTH_URL"),
        client_id=os.getenv("AICORE_CLIENT_ID"),
        client_secret=os.getenv("AICORE_CLIENT_SECRET"),
        resource_group=os.getenv("AICORE_RESOURCE_GROUP", "default"),
    )

    corruption_config = LLMSessionConfig(
        model_name=model,
        temperature=TEMPERATURE,
        max_tokens=MAX_TOKENS,
        deployment_id=deployment_id,
        system_message="",  # Will be set by Database
        base_url=os.getenv("AICORE_BASE_URL"),
        auth_url=os.getenv("AICORE_AUTH_URL"),
        client_id=os.getenv("AICORE_CLIENT_ID"),
        client_secret=os.getenv("AICORE_CLIENT_SECRET"),
        resource_group=os.getenv("AICORE_RESOURCE_GROUP", "default"),
    )

    return check_config, corruption_config


def load_database_data(db, database_type: str):
    """Load test data into the database based on database type.

    Args:
        db: Database instance to load data into
        database_type: Type of database ("rel_stack", "rel_f1", "rel_trial")

    Returns:
        bool: True if data was loaded successfully
    """
    logger.info(f"Loading test data from {DATA_DIR}...")
    data_dir = Path(DATA_DIR)

    # Database-specific table mappings
    database_tables = {
        "rel_stack": ["Users", "Posts", "Badges", "PostHistory", "Comments", "Votes", "PostLinks"],
        "rel_f1": [
            "Circuits",
            "Drivers",
            "Constructors",
            "Races",
            "Qualifying",
            "Results",
            "ConstructorResults",
            "ConstructorStandings",
            "DriverStandings",
            "LapTimes",
            "PitStops",
            "Seasons",
            "Status",
        ],
        "rel_trial": [
            "Studies",
            "Outcomes",
            "OutcomeAnalyses",
            "DropWithdrawals",
            "ReportedEventTotals",
            "Designs",
            "Eligibilities",
            "Interventions",
            "Conditions",
            "Facilities",
            "Sponsors",
            "InterventionsStudies",
            "ConditionsStudies",
            "FacilitiesStudies",
            "SponsorsStudies",
        ],
    }

    tables = database_tables.get(database_type, [])

    # Filter tables based on table_scopes if set
    if db.get_table_scopes:
        tables = [t for t in tables if t in db.get_table_scopes]
        logger.info(f"Filtering to tables in scope: {tables}")

    loaded_count = 0

    for table_name in tables:
        file_path = data_dir / f"{table_name}.csv"
        if file_path.exists():
            try:
                db.load_table_data_from_csv(table_name, str(file_path))
                loaded_count += 1
                logger.debug(f"Loaded {table_name} from {file_path}")
            except Exception as e:
                logger.warning(f"Failed to load {table_name}: {e}")
        else:
            logger.warning(f"File not found: {file_path}")

    logger.info(f"Loaded {loaded_count}/{len(tables)} tables")
    return loaded_count > 0


def main(args):
    """Main workflow function for agent-based check generation and evaluation."""

    # Load environment first
    load_dotenv()

    logger.info("=" * 60)
    logger.info("Starting Agent Workflow")
    logger.info("=" * 60)

    # Generate database ID with version and optional UUID
    if not args.no_uuid:
        run_uuid = str(uuid.uuid4())[:8]  # Use first 8 chars for readability
        database_id = f"{BASE_DATABASE_ID}_{run_uuid}"
    else:
        database_id = f"{BASE_DATABASE_ID}"

    # Create result directory based on database_id
    result_dir = Path(BASE_RESULT_DIR) / database_id / "result"
    result_dir.mkdir(parents=True, exist_ok=True)

    # Setup logging with result directory
    log_file = str(result_dir / "agent_workflow.log")
    setup_logging(LOG_LEVEL, log_file)

    logger.info(f"Database ID: {database_id}")
    logger.info(f"Results directory: {result_dir}")

    try:
        # Step 1: Initialize LLM Session Manager
        logger.info("Step 1: Initializing LLM session manager...")
        session_manager = LLMSessionManager()

        # Step 2: Create LLM configurations
        logger.info("Step 2: Creating LLM configurations...")
        # Parse model type
        model_map = {"claude-3.7": LLMProvider.ANTHROPIC_CLAUDE_3_7, "claude-4": LLMProvider.ANTHROPIC_CLAUDE_4}
        check_model = model_map[args.model]
        check_config, corruption_config = create_llm_configs(check_model, args.deployment_id)

        # Step 3: Initialize Database
        logger.info(f"Step 3: Initializing {args.database.upper()} database...")
        if args.version == "v1":
            logger.info(f"Using version mode: {args.version}")

        # Parse table scopes if set
        table_scopes = set()
        if args.table_scopes:
            table_scopes = {t.strip() for t in args.table_scopes.split(",") if t.strip()}
            logger.info(f"Table scopes configured: {sorted(table_scopes)}")

        # Calculate max_output_tokens with margin
        max_output_tokens = 10000  # Leave 500 token margin
        db = DATABASE_CLASS(
            database_id=database_id,
            max_output_tokens=max_output_tokens,
            table_scopes=table_scopes,
            max_execution_time=args.timeout,
        )

        # Log the actual scoped tables
        logger.info(f"Database initialized with {len(db.table_classes)} total tables")
        logger.info(f"Scoped tables available: {list(db.scoped_table_classes.keys())}")

        # Step 4: Load test data
        logger.info("Step 4: Loading test data...")
        if not load_database_data(db, args.database):
            logger.error("Failed to load test data")
            return 1

        # Step 5: Generate checks using agent
        logger.info(f"Step 5: Generating checks using agent...")
        logger.info("Calling agent_check_generation...")

        # Create progress collector for agent activity
        from definition.llm.interactive.streaming_progress import StreamingProgressCollector

        progress_collector = StreamingProgressCollector()

        # Use the appropriate agent to generate checks with progress callback
        match args.version:
            case "v1":
                agent = CheckGenerationAgentV1(database=db, session_manager=session_manager, config=check_config)
                generated_checks = agent.generate_checks(
                    user_message=USER_MESSAGE, progress_callback=progress_collector
                )
            case "v2":
                agent = CheckGenerationAgentV2(database=db, session_manager=session_manager, config=check_config)
                generated_checks = agent.generate_checks(
                    user_message=USER_MESSAGE, max_iterations=args.max_iterations, progress_callback=progress_collector
                )
            case "v3":
                from definition.agents.check_generation_agent_v3 import CheckGenerationAgentV3

                agent = CheckGenerationAgentV3(database=db, session_manager=session_manager, config=check_config)
                generated_checks = agent.generate_checks(
                    user_message=USER_MESSAGE, max_iterations=args.max_iterations, progress_callback=progress_collector
                )
            case _:
                raise ValueError(f"Unknown version mode: {args.version}")

        logger.info(f"Generated {len(generated_checks)} checks")

        # Step 6: Validate using the generated checks
        logger.info("Step 6: Running validation...")

        # Run validation (returns unified dict with both violations and exceptions)
        validation_results = db.validate()

        # Separate violations from exceptions for counting
        violations_dict = {k: v for k, v in validation_results.items() if isinstance(v, pd.DataFrame)}
        exceptions_dict = {k: v for k, v in validation_results.items() if isinstance(v, Exception)}

        number_of_runnable_checks = len(violations_dict) + len(exceptions_dict)

        logger.info(
            f"Validation completed: {len(violations_dict)} checks succeeded, {len(exceptions_dict)} checks failed"
        )

        # Step 7: Evaluate against ground truth
        logger.info("Step 7: Evaluating against ground truth...")
        logger.info(f"Loading ground truth from {GROUND_TRUTH_FILE}")

        # Use database's evaluate method which handles everything internally
        report = db.evaluate(GROUND_TRUTH_FILE)

        # Step 8: Export results
        logger.info(f"Step 8: Exporting results to {result_dir}...")

        # Export validation results using Database's export method
        db.export_validation_result(str(result_dir), override_existing_files=True)
        logger.info(f"  Saved violations to {result_dir / 'violations.csv'}")

        # Save evaluation report
        report_file = result_dir / "evaluation_report.csv"
        report.to_csv(report_file, index=False)
        logger.info(f"  Saved evaluation report to {report_file}")

        # Save generated checks with code included
        checks_file = result_dir / "generated_checks.json"
        import json

        checks_data = []
        for check in generated_checks.values():
            check_dict = check.to_dict()
            # to_dict() already includes all necessary fields
            checks_data.append(check_dict)
        with open(checks_file, "w") as f:
            json.dump(checks_data, f, indent=2)
        logger.info(f"  Saved generated checks to {checks_file}")

        # Save agent generation history
        history_file = result_dir / "agent_check_generation_history.txt"
        with open(history_file, "w") as f:
            f.write(progress_collector.get_formatted_progress())
        logger.info(f"  Saved agent history to {history_file}")

        # Save full chat history as JSON
        chat_history_file = result_dir / "chat_history.json"
        try:
            # Get the conversation history from the session
            session = session_manager.get_session(agent.session_id)
            if session and hasattr(session, "conversation_history"):
                chat_history = []
                # Add system message if present
                if session.config.system_message:
                    chat_history.append(
                        {
                            "role": "system",
                            "content": session.config.system_message,
                            "timestamp": session.created_at if hasattr(session, "created_at") else None,
                        }
                    )
                for msg in session.conversation_history:
                    chat_history.append(
                        {
                            "role": msg.role.value if hasattr(msg.role, "value") else str(msg.role),
                            "content": msg.content,
                            "timestamp": msg.timestamp if hasattr(msg, "timestamp") else None,
                        }
                    )
                with open(chat_history_file, "w") as f:
                    json.dump(chat_history, f, indent=2)
                logger.info(f"  Saved chat history to {chat_history_file}")
            else:
                logger.warning(f"No conversation history found for session {agent.session_id}")
        except Exception as e:
            logger.warning(f"Could not save chat history: {e}")

        # Save executed queries if V2 agent was used
        if (
            args.version == "v2"
            and hasattr(progress_collector, "executed_queries")
            and progress_collector.executed_queries
        ):
            queries_file = result_dir / "executed_queries.json"
            with open(queries_file, "w") as f:
                json.dump(progress_collector.executed_queries, f, indent=2)
            logger.info(f"  Saved {len(progress_collector.executed_queries)} executed queries to {queries_file}")

        # Step 9: Extract and append overall results to OVERALL.csv
        logger.info("Step 9: Appending overall results to OVERALL.csv...")

        # Extract the OVERALL row from the evaluation report
        overall_row = report[report["check_name"] == "OVERALL"].copy()

        if not overall_row.empty:
            # Remove check_name column since it's always OVERALL
            overall_row = overall_row.drop(columns=["check_name"])

            # Add additional columns
            overall_row["database_id"] = database_id
            overall_row["database_type"] = args.database
            overall_row["check_model"] = check_model.value  # Get the string value of the enum
            overall_row["max_iterations"] = args.max_iterations
            overall_row["number_of_generated_checks"] = len(generated_checks)
            overall_row["number_of_runnable_checks"] = number_of_runnable_checks
            # Add table_scopes column - convert set to comma-separated string or "all" if empty
            overall_row["table_scopes"] = ",".join(sorted(db.get_table_scopes)) if db.get_table_scopes else "all"

            # Define preferred column order (metadata first, then metrics)
            metadata_cols = [
                "database_id",
                "database_type",
                "table_scopes",
                "check_model",
                "max_iterations",
                "number_of_generated_checks",
                "number_of_runnable_checks",
            ]
            metric_cols = [col for col in overall_row.columns if col not in metadata_cols]
            ordered_cols = metadata_cols + metric_cols
            overall_row = overall_row[ordered_cols]

            # Create OVERALL.csv path
            overall_file = Path(OVERALL)
            overall_file.parent.mkdir(parents=True, exist_ok=True)

            # Check if file exists and has the same columns
            if overall_file.exists():
                existing_df = pd.read_csv(overall_file)
                # Ensure columns match
                for col in overall_row.columns:
                    if col not in existing_df.columns:
                        existing_df[col] = None
                for col in existing_df.columns:
                    if col not in overall_row.columns:
                        overall_row[col] = None
                # Reorder columns to match existing file
                overall_row = overall_row[existing_df.columns]
                # Append the new row
                updated_df = pd.concat([existing_df, overall_row], ignore_index=True)
                updated_df.to_csv(overall_file, index=False)
                logger.info(f"  Appended overall results to {overall_file}")
            else:
                # Create new file with preferred column order
                overall_row.to_csv(overall_file, index=False)
                logger.info(f"  Created {overall_file} with overall results")
        else:
            logger.warning("No OVERALL row found in evaluation report")

        logger.success("=" * 60)
        logger.success("Workflow completed successfully!")
        logger.success(f"All results saved to: {result_dir}")
        logger.success("=" * 60)

        return 0

    except Exception as e:
        logger.error(f"Workflow failed with error: {e}")
        if LOG_LEVEL == "DEBUG":
            import traceback

            logger.debug(traceback.format_exc())
        return 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run agent workflow for check generation and evaluation")
    parser.add_argument(
        "--database",
        type=str,
        default="rel_stack",
        choices=["rel_stack", "rel_f1", "rel_trial"],
        help="Database type to use",
    )
    parser.add_argument("--max-iterations", type=int, default=100, help="Maximum iterations for agents (default: 100)")
    parser.add_argument(
        "--version",
        choices=["v1", "v2", "v3"],
        default="v2",
        help="Version mode: v1=baseline, v2=agent iteration, v3=intelligent routing",
    )
    parser.add_argument("--no-uuid", action="store_true", help="Don't append UUID to database ID")
    parser.add_argument(
        "--table-scopes",
        type=str,
        default="",
        help="Comma-separated list of table names to focus on (e.g., 'Table1,Table2'). Empty means all tables.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=120,
        help="Maximum execution time in seconds for database operations (default: 30)",
    )
    parser.add_argument(
        "--deployment-id",
        type=str,
        help="AI Core deployment ID",
    )
    parser.add_argument(
        "--model",
        choices=["claude-3.7", "claude-4"],
        default="claude-3.7",
        help="Model for check generation (default: claude-3.7)",
    )

    args = parser.parse_args()

    # Get database configuration
    if args.database not in DATABASE_CONFIGS:
        print(f"Error: Invalid database type '{args.database}'")
        sys.exit(1)

    CURRENT_CONFIG = DATABASE_CONFIGS[args.database]
    DATABASE_CLASS = CURRENT_CONFIG["class"]
    BASE_DATABASE_ID = f"{CURRENT_CONFIG['base_id']}_{args.version}"
    DATA_DIR = CURRENT_CONFIG["data_dir"]
    GROUND_TRUTH_FILE = CURRENT_CONFIG["ground_truth"]
    BASE_RESULT_DIR = CURRENT_CONFIG["result_dir"]
    OVERALL = CURRENT_CONFIG["overall_file"]
    USER_MESSAGE = CURRENT_CONFIG["user_message"]

    sys.exit(main(args))
