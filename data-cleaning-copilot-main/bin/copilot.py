#!/usr/bin/env python3
"""Database Quality Agent - Interactive check generation and improvement."""

import argparse
import os
import sys
from pathlib import Path
from loguru import logger
from dotenv import load_dotenv

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from definition.impl.database.rel_stack import RelStack
from definition.llm.session_manager import LLMSessionManager
from definition.llm.models import LLMProvider, LLMSessionConfig
from definition.llm.interactive.session import InteractiveSession
from relbench.datasets import get_dataset


def load_relstack_data(db, data_dir: Path | None = None):
    """Load rel-stack data from CSV files or RelBench."""
    table_mapping = {
        "badges": "Badges",
        "postHistory": "PostHistory",
        "users": "Users",
        "votes": "Votes",
        "comments": "Comments",
        "posts": "Posts",
        "postLinks": "PostLinks",
    }

    if data_dir and data_dir.exists():
        # Load from CSV files
        logger.info(f"Loading rel-stack data from {data_dir}...")
        loaded_count = 0
        for rel_name, table_name in table_mapping.items():
            # Try different naming conventions
            csv_files = [
                data_dir / f"{table_name}.csv",
                data_dir / f"{rel_name}.csv",
                data_dir / f"{table_name.lower()}.csv",
            ]

            for csv_file in csv_files:
                if csv_file.exists():
                    try:
                        db.load_table_data_from_csv(table_name, str(csv_file))
                        loaded_count += 1
                        logger.debug(f"Loaded {table_name} from {csv_file}")
                        break
                    except Exception as e:
                        logger.warning(f"Failed to load {table_name} from {csv_file}: {e}")
            else:
                logger.warning(f"No CSV file found for {table_name}")

        return loaded_count, len(table_mapping)
    else:
        # Load from RelBench
        logger.info("Loading rel-stack dataset from RelBench...")
        dataset = get_dataset("rel-stack")
        db_relbench = dataset.get_db()

        loaded_count = 0
        for rel_table_name, our_table_name in table_mapping.items():
            try:
                if rel_table_name in db_relbench.table_dict:
                    df = db_relbench.table_dict[rel_table_name].df
                    db.set_table_data(our_table_name, df)
                    logger.debug(f"Loaded {our_table_name} with {len(df)} rows")
                    loaded_count += 1
                else:
                    logger.warning(f"Table {rel_table_name} not found in RelBench dataset")
            except Exception as e:
                logger.warning(f"Failed to load {our_table_name}: {e}")

        return loaded_count, len(table_mapping)


def main():
    """Main entry point for the database quality agent."""
    parser = argparse.ArgumentParser(
        description="Database Quality Agent - Interactive check generation and improvement",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    # Database selection
    parser.add_argument(
        "--database", "-d", choices=["rel-stack"], required=True, help="Database type to analyze"
    )

    # Model selection for interactive session
    parser.add_argument(
        "--session-model",
        choices=["claude-3.7", "claude-4"],
        default="claude-4",
        help="Model for interactive session (default: claude-4)",
    )

    # Model selection for agents (check and corruption generation)
    parser.add_argument(
        "--agent-model",
        choices=["claude-3.7", "claude-4"],
        default="claude-4",
        help="Model for agents (default: claude-3.7 for cost efficiency)",
    )

    # Deployment IDs for AI Core
    parser.add_argument(
        "--session-deployment-id",
        type=str,
        help="AI Core deployment ID for interactive session (default: da2b3b967c256b09)",
    )
    parser.add_argument(
        "--agent-deployment-id",
        type=str,
        help="AI Core deployment ID for agents (default: da2b3b967c256b09)",
    )

    # Data loading
    parser.add_argument(
        "--data-dir",
        default="",
        help="Directory containing test data CSV files. If not specified, rel-stack loads from RelBench",
    )

    # Interactive options
    parser.add_argument("--port", type=int, default=7860, help="Port for interactive web interface (default: 7860)")

    # Database operation parameters
    parser.add_argument(
        "--timeout",
        type=int,
        default=120,
        help="Maximum execution time in seconds for database operations (default: 120)",
    )

    parser.add_argument(
        "--max-tokens", type=int, default=10000, help="Maximum tokens for LLM responses (default: 10000)"
    )

    parser.add_argument(
        "--table-scopes",
        type=str,
        default="",
        help="Comma-separated list of table names to focus on (e.g., 'Table1,Table2'). Empty means all tables.",
    )

    # Logging
    parser.add_argument("--verbose", "-v", action="store_true", help="Enable verbose logging")

    args = parser.parse_args()

    # Configure logging
    log_level = "DEBUG" if args.verbose else "INFO"
    logger.remove()
    logger.add(sys.stderr, level=log_level)

    # Load environment variables
    load_dotenv()

    # Parse table_scopes parameter
    table_scopes = set()
    if args.table_scopes:
        table_scopes = {t.strip() for t in args.table_scopes.split(",") if t.strip()}

    logger.info("Database Quality Agent Starting")
    logger.info(f"Database: {args.database}")
    logger.info(f"Session Model: {args.session_model}")
    logger.info(f"Agent Model: {args.agent_model}")

    # Model mapping
    model_map = {"claude-3.7": LLMProvider.ANTHROPIC_CLAUDE_3_7, "claude-4": LLMProvider.ANTHROPIC_CLAUDE_4}

    session_deployment_id = args.session_deployment_id
    agent_deployment_id = args.agent_deployment_id

    try:
        # Create LLM session manager
        logger.info("Creating LLM session manager...")
        session_manager = LLMSessionManager()

        # Configuration for interactive session
        session_config = LLMSessionConfig(
            model_name=model_map[args.session_model],
            temperature=0.1,
            max_tokens=args.max_tokens,
            deployment_id=session_deployment_id,
            base_url=os.getenv("AICORE_BASE_URL"),
            auth_url=os.getenv("AICORE_AUTH_URL"),
            client_id=os.getenv("AICORE_CLIENT_ID"),
            client_secret=os.getenv("AICORE_CLIENT_SECRET"),
            resource_group=os.getenv("AICORE_RESOURCE_GROUP", "default"),
        )

        # Separate configuration for agents (can use different model for cost efficiency)
        agent_config = LLMSessionConfig(
            model_name=model_map[args.agent_model],
            temperature=0.7,  # Higher temperature for more creative generation
            max_tokens=args.max_tokens,
            deployment_id=agent_deployment_id,
            base_url=os.getenv("AICORE_BASE_URL"),
            auth_url=os.getenv("AICORE_AUTH_URL"),
            client_id=os.getenv("AICORE_CLIENT_ID"),
            client_secret=os.getenv("AICORE_CLIENT_SECRET"),
            resource_group=os.getenv("AICORE_RESOURCE_GROUP", "default"),
        )

        # Initialize database
        logger.info(f"Initializing {args.database.upper()} database...")

        # Calculate max_output_tokens with margin (using session config's max_tokens)
        max_output_tokens = args.max_tokens - 500  # Leave 500 token margin

        # Create database instance based on type with all parameters
        if args.database == "rel-stack":
            db = RelStack(
                database_id="rel_stack_agent",
                max_output_tokens=max_output_tokens,
                table_scopes=table_scopes,
                max_execution_time=args.timeout,
            )
        else:
            raise ValueError(f"Unknown database type: {args.database}")

        # Load data based on database type
        if args.database == "rel-stack":
            data_dir = Path(args.data_dir) if args.data_dir else None
            loaded_count, total_count = load_relstack_data(db, data_dir)
        else:
            loaded_count, total_count = 0, 0

        logger.info(f"Loaded {loaded_count}/{total_count} tables")

        # Create interactive session with separate agent config
        logger.info("Creating interactive session...")
        interactive_session = InteractiveSession(
            database=db,
            session_manager=session_manager,
            config=session_config,
            session_id=f"{args.database}_interactive_agent",
            agent_config=agent_config,
        )

        logger.success(f"Interactive session created: {interactive_session.session_id}")

        # Show capabilities
        logger.info("\nInteractive Session Capabilities:")
        logger.info("  ✓ Database validation and exploration")
        logger.info("  ✓ Schema and data inspection")
        logger.info("  ✓ Natural language querying")
        logger.info("  ✓ Real-time validation feedback")
        logger.info("  ✓ Check and corruption management")

        logger.info("\nNote: For agent-based check/corruption generation:")
        logger.info("  Use check_generation_v1, check_generation_v2, or corruption_generation function calls")
        logger.info(f"  Agents will use {args.agent_model} model for generation")
        logger.info("  The interactive session will handle agent instantiation automatically")

        logger.info("\n" + "=" * 60)
        logger.info("Starting Interactive Web Interface...")
        logger.info(f"URL: http://localhost:{args.port}")
        logger.info("=" * 60)

        # Start the interactive session
        interactive_session.start(share=False, port=args.port)

        return 0

    except Exception as e:
        logger.error(f"Agent failed with error: {e}")
        if args.verbose:
            import traceback

            logger.debug(traceback.format_exc())
        return 1


if __name__ == "__main__":
    sys.exit(main())
