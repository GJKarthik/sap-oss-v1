#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Download and prepare RelBench datasets for benchmark generation."""

import sys
from pathlib import Path
from loguru import logger

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))


def download_rel_stack():
    """Download and save Stack Overflow data from RelBench."""
    from relbench.datasets import get_dataset
    from definition.impl.database.rel_stack import RelStack

    logger.info("Downloading Stack Overflow dataset from RelBench...")
    dataset = get_dataset("rel-stack", download=True)
    db_relbench = dataset.get_db()

    # Create output directory
    output_dir = Path("data/rel_stack")
    output_dir.mkdir(parents=True, exist_ok=True)

    # Create our database and load RelBench data
    db = RelStack("rel_stack_temp")

    # Map RelBench table names to our schema
    table_mapping = {
        "users": "Users",
        "posts": "Posts",
        "badges": "Badges",
        "posthistory": "PostHistory",
        "comments": "Comments",
        "votes": "Votes",
        "postlinks": "PostLinks",
    }

    loaded = 0
    for rel_name, our_name in table_mapping.items():
        if rel_name in db_relbench.table_dict:
            df = db_relbench.table_dict[rel_name].df
            # Sample data to keep it manageable (10000 rows max)
            if len(df) > 10000:
                df = df.sample(n=10000, random_state=42)
            db.set_table_data(our_name, df)
            # Export to CSV
            csv_path = output_dir / f"{our_name}.csv"
            df.to_csv(csv_path, index=False)
            logger.info(f"Saved {our_name} with {len(df)} rows to {csv_path}")
            loaded += 1
        else:
            logger.warning(f"Table {rel_name} not found in RelBench dataset")

    logger.success(f"Downloaded and saved {loaded} tables to {output_dir}")
    return loaded


def download_rel_f1():
    """Download and save F1 data from RelBench."""
    from relbench.datasets import get_dataset
    from definition.impl.database.rel_f1 import RelF1

    logger.info("Downloading F1 dataset from RelBench...")
    dataset = get_dataset("rel-f1", download=True)
    db_relbench = dataset.get_db()

    # Create output directory
    output_dir = Path("data/rel_f1")
    output_dir.mkdir(parents=True, exist_ok=True)

    # Create our database and load RelBench data
    db = RelF1("rel_f1_temp")

    # Map RelBench table names to our schema
    table_mapping = {
        "circuits": "Circuits",
        "drivers": "Drivers",
        "constructors": "Constructors",
        "races": "Races",
        "qualifying": "Qualifying",
        "results": "Results",
        "constructor_results": "ConstructorResults",
        "constructor_standings": "ConstructorStandings",
        "driver_standings": "DriverStandings",
        "lap_times": "LapTimes",
        "pit_stops": "PitStops",
        "seasons": "Seasons",
        "status": "Status",
    }

    loaded = 0
    for rel_name, our_name in table_mapping.items():
        if rel_name in db_relbench.table_dict:
            df = db_relbench.table_dict[rel_name].df
            # Sample data to keep it manageable (10000 rows max)
            if len(df) > 10000:
                df = df.sample(n=10000, random_state=42)
            db.set_table_data(our_name, df)
            # Export to CSV
            csv_path = output_dir / f"{our_name}.csv"
            df.to_csv(csv_path, index=False)
            logger.info(f"Saved {our_name} with {len(df)} rows to {csv_path}")
            loaded += 1
        else:
            logger.warning(f"Table {rel_name} not found in RelBench dataset")

    logger.success(f"Downloaded and saved {loaded} tables to {output_dir}")
    return loaded


def download_rel_trial():
    """Download and save clinical trials data from RelBench."""
    from relbench.datasets import get_dataset
    from definition.impl.database.rel_trial import RelTrial

    logger.info("Downloading clinical trials dataset from RelBench...")
    dataset = get_dataset("rel-trial", download=True)
    db_relbench = dataset.get_db()

    # Create output directory
    output_dir = Path("data/rel_trial")
    output_dir.mkdir(parents=True, exist_ok=True)

    # Create our database and load RelBench data
    db = RelTrial("rel_trial_temp")

    # Map RelBench table names to our schema
    table_mapping = {
        "studies": "Studies",
        "outcomes": "Outcomes",
        "outcome_analyses": "OutcomeAnalyses",
        "drop_withdrawals": "DropWithdrawals",
        "reported_event_totals": "ReportedEventTotals",
        "designs": "Designs",
        "eligibilities": "Eligibilities",
        "interventions": "Interventions",
        "conditions": "Conditions",
        "facilities": "Facilities",
        "sponsors": "Sponsors",
        "interventions_studies": "InterventionsStudies",
        "conditions_studies": "ConditionsStudies",
        "facilities_studies": "FacilitiesStudies",
        "sponsors_studies": "SponsorsStudies",
    }

    loaded = 0
    for rel_name, our_name in table_mapping.items():
        if rel_name in db_relbench.table_dict:
            df = db_relbench.table_dict[rel_name].df
            # Sample data to keep it manageable (10000 rows max)
            if len(df) > 10000:
                df = df.sample(n=10000, random_state=42)
            db.set_table_data(our_name, df)
            # Export to CSV
            csv_path = output_dir / f"{our_name}.csv"
            df.to_csv(csv_path, index=False)
            logger.info(f"Saved {our_name} with {len(df)} rows to {csv_path}")
            loaded += 1
        else:
            logger.warning(f"Table {rel_name} not found in RelBench dataset")

    logger.success(f"Downloaded and saved {loaded} tables to {output_dir}")
    return loaded


def main():
    """Main entry point."""
    logger.remove()
    logger.add(sys.stderr, level="INFO")

    logger.info("=" * 60)
    logger.info("RelBench Data Downloader")
    logger.info("=" * 60)

    total_loaded = 0

    try:
        # Download Stack Overflow data
        logger.info("\n1. Downloading Stack Overflow data...")
        loaded = download_rel_stack()
        total_loaded += loaded
    except Exception as e:
        logger.error(f"Failed to download Stack Overflow data: {e}")

    try:
        # Download F1 data
        logger.info("\n2. Downloading F1 data...")
        loaded = download_rel_f1()
        total_loaded += loaded
    except Exception as e:
        logger.error(f"Failed to download F1 data: {e}")

    try:
        # Download Clinical Trials data
        logger.info("\n3. Downloading Clinical Trials data...")
        loaded = download_rel_trial()
        total_loaded += loaded
    except Exception as e:
        logger.error(f"Failed to download Clinical Trials data: {e}")

    logger.info("=" * 60)
    logger.success(f"Download complete! Total tables downloaded: {total_loaded}")
    logger.info("Data saved to:")
    logger.info("  - data/rel_stack/")
    logger.info("  - data/rel_f1/")
    logger.info("  - data/rel_trial/")

    return 0


if __name__ == "__main__":
    sys.exit(main())
