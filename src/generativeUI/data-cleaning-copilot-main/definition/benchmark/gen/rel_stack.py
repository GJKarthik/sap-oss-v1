#!/usr/bin/env python3
"""Benchmark data generation for RelStack (Stack Overflow) database.

This script generates corrupted datasets and ground truth checks for benchmarking
error detection models on Stack Overflow data.
"""

import json
import sys
from pathlib import Path
from typing import Dict
from datetime import datetime
from loguru import logger
import pandas as pd

# Add parent directories to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent.parent))

from definition.impl.database.rel_stack import RelStack
from definition.base.executable_code import CorruptionLogic, CheckLogic


def create_manual_corruptors() -> Dict[str, CorruptionLogic]:
    """Create manually defined corruptors for benchmark.

    Returns:
        Dictionary of corruptor name to CorruptionLogic instances
    """
    corruptors = {}

    # 1. Make regular posts (PostTypeId=1) have more than 5 tags
    corruptors["posts_too_many_tags"] = CorruptionLogic(
        function_name="corrupt_posts_too_many_tags",
        description="Add more than 5 tags to regular posts (PostTypeId=1)",
        parameters="table_data: Mapping[str, pd.DataFrame], rand: random.Random, percentage_per_column: Mapping[Tuple[str, str], float]",
        body_lines=[
            "    posts_df = table_data['Posts'].copy()",
            "    ",
            "    # Get percentage for this corruption",
            "    percentage = percentage_per_column.get(('Posts', 'Tags'), 0.1) if isinstance(percentage_per_column, dict) else 0.1",
            "    ",
            "    # Pool of realistic Stack Overflow tags to add",
            "    tag_pool = [",
            "        'python', 'javascript', 'java', 'c#', 'php', 'android', 'html', 'jquery',",
            "        'c++', 'css', 'ios', 'sql', 'mysql', 'r', 'node.js', 'reactjs', 'arrays',",
            "        'c', 'asp.net', 'json', 'ruby-on-rails', 'python-3.x', 'swift', 'django',",
            "        'angular', 'excel', 'regex', 'pandas', 'flutter', 'spring', 'typescript',",
            "        'mongodb', 'postgresql', 'numpy', 'vba', 'docker', 'kotlin', 'go', 'rust',",
            "        'scala', 'elasticsearch', 'redis', 'kubernetes', 'apache-spark', 'tensorflow',",
            "        'machine-learning', 'deep-learning', 'data-science', 'statistics', 'algorithm',",
            "        'data-structures', 'api', 'rest', 'graphql', 'microservices', 'aws', 'azure',",
            "        'google-cloud', 'firebase', 'authentication', 'security', 'encryption', 'testing',",
            "        'unit-testing', 'debugging', 'performance', 'optimization', 'database-design'",
            "    ]",
            "    ",
            "    # Find regular posts (PostTypeId=1) with tags",
            "    regular_posts = posts_df[(posts_df['PostTypeId'] == 1) & (posts_df['Tags'].notna())]",
            "    ",
            "    if len(regular_posts) > 0:",
            "        n_corrupt = max(1, int(len(regular_posts) * percentage))",
            "        corrupt_indices = rand.sample(list(regular_posts.index), min(n_corrupt, len(regular_posts)))",
            "        ",
            "        for idx in corrupt_indices:",
            "            existing_tags = str(posts_df.loc[idx, 'Tags'])",
            "            # Count existing tags",
            "            import re",
            "            tag_pattern = r'<([^<>]+)>'",
            "            existing_tag_list = re.findall(tag_pattern, existing_tags)",
            "            ",
            "            # Add extra tags to make it more than 5",
            "            extra_tags_needed = max(6 - len(existing_tag_list), rand.randint(2, 5))",
            "            # Select random tags that aren't already in the post",
            "            available_tags = [t for t in tag_pool if t not in existing_tag_list]",
            "            if available_tags:",
            "                selected_tags = rand.sample(available_tags, min(extra_tags_needed, len(available_tags)))",
            "                new_tags = [f'<{tag}>' for tag in selected_tags]",
            "                # Append new tags",
            "                corrupted = existing_tags + ''.join(new_tags)",
            "                posts_df.loc[idx, 'Tags'] = corrupted",
            "        print(f'Added extra tags to {len(corrupt_indices)} regular posts')",
            "    ",
            "    table_data['Posts'] = posts_df",
            "    return table_data",
        ],
        return_statement="table_data",
        scope=[("Posts", "Tags"), ("Posts", "PostTypeId")],
    )

    # 2. Make answers (PostTypeId=2) have tags (they shouldn't)
    corruptors["answers_with_tags"] = CorruptionLogic(
        function_name="corrupt_answers_with_tags",
        description="Add tags to answer posts (PostTypeId=2) which shouldn't have tags",
        parameters="table_data: Mapping[str, pd.DataFrame], rand: random.Random, percentage_per_column: Mapping[Tuple[str, str], float]",
        body_lines=[
            "    posts_df = table_data['Posts'].copy()",
            "    ",
            "    # Get percentage for this corruption",
            "    percentage = percentage_per_column.get(('Posts', 'Tags'), 0.1) if isinstance(percentage_per_column, dict) else 0.1",
            "    ",
            "    # Pool of realistic Stack Overflow tags",
            "    tag_pool = [",
            "        'python', 'javascript', 'java', 'c#', 'php', 'android', 'html', 'jquery',",
            "        'c++', 'css', 'ios', 'sql', 'mysql', 'r', 'node.js', 'reactjs', 'arrays',",
            "        'c', 'asp.net', 'json', 'ruby-on-rails', 'python-3.x', 'swift', 'django',",
            "        'angular', 'excel', 'regex', 'pandas', 'flutter', 'spring', 'typescript',",
            "        'mongodb', 'postgresql', 'numpy', 'vba', 'docker', 'kotlin', 'go', 'rust'",
            "    ]",
            "    ",
            "    # Find answers (PostTypeId=2)",
            "    answers = posts_df[posts_df['PostTypeId'] == 2]",
            "    ",
            "    if len(answers) > 0:",
            "        n_corrupt = max(1, int(len(answers) * percentage))",
            "        corrupt_indices = rand.sample(list(answers.index), min(n_corrupt, len(answers)))",
            "        ",
            "        for idx in corrupt_indices:",
            "            # Add 1-3 random tags to the answer",
            "            num_tags = rand.randint(1, 3)",
            "            selected_tags = rand.sample(tag_pool, min(num_tags, len(tag_pool)))",
            "            formatted_tags = ''.join([f'<{tag}>' for tag in selected_tags])",
            "            posts_df.loc[idx, 'Tags'] = formatted_tags",
            "        print(f'Added tags to {len(corrupt_indices)} answer posts')",
            "    ",
            "    table_data['Posts'] = posts_df",
            "    return table_data",
        ],
        return_statement="table_data",
        scope=[("Posts", "Tags"), ("Posts", "PostTypeId")],
    )

    # 3. Make users self-vote for their own posts
    corruptors["self_voting"] = CorruptionLogic(
        function_name="corrupt_self_voting",
        description="Create votes where users vote for their own posts",
        parameters="table_data: Mapping[str, pd.DataFrame], rand: random.Random, percentage_per_column: Mapping[Tuple[str, str], float]",
        body_lines=[
            "    votes_df = table_data['Votes'].copy()",
            "    posts_df = table_data['Posts']",
            "    ",
            "    # Get percentage for this corruption",
            "    percentage = percentage_per_column.get(('Votes', 'UserId'), 0.1) if isinstance(percentage_per_column, dict) else 0.1",
            "    ",
            "    # Find posts with OwnerUserId",
            "    posts_with_owner = posts_df[posts_df['OwnerUserId'].notna()]",
            "    ",
            "    if len(posts_with_owner) > 0:",
            "        n_corrupt = max(1, int(len(posts_with_owner) * percentage))",
            "        posts_to_corrupt = posts_with_owner.sample(n=min(n_corrupt, len(posts_with_owner)), random_state=rand.randint(0, 2**32-1))",
            "        ",
            "        new_votes = []",
            "        max_vote_id = votes_df['Id'].max() if 'Id' in votes_df.columns else 0",
            "        ",
            "        for idx, post in posts_to_corrupt.iterrows():",
            "            # Create a self-vote",
            "            new_vote = {",
            "                'Id': max_vote_id + len(new_votes) + 1,",
            "                'PostId': post['Id'],",
            "                'UserId': post['OwnerUserId'],",
            "                'VoteTypeId': rand.choice([2, 3]),  # 2=UpVote, 3=DownVote",
            "                'CreationDate': pd.to_datetime(post['CreationDate']) + pd.Timedelta(hours=rand.randint(1, 24))",
            "            }",
            "            # Add other columns with default values if they exist in votes_df",
            "            for col in votes_df.columns:",
            "                if col not in new_vote:",
            "                    new_vote[col] = None",
            "            new_votes.append(new_vote)",
            "        ",
            "        if new_votes:",
            "            new_votes_df = pd.DataFrame(new_votes)",
            "            votes_df = pd.concat([votes_df, new_votes_df], ignore_index=True)",
            "            print(f'Created {len(new_votes)} self-votes')",
            "    ",
            "    table_data['Votes'] = votes_df",
            "    return table_data",
        ],
        return_statement="table_data",
        scope=[("Votes", "UserId"), ("Votes", "PostId"), ("Posts", "OwnerUserId")],
    )

    # 4. Make posts link to themselves
    corruptors["self_linking_posts"] = CorruptionLogic(
        function_name="corrupt_self_linking_posts",
        description="Create PostLinks where posts link to themselves",
        parameters="table_data: Mapping[str, pd.DataFrame], rand: random.Random, percentage_per_column: Mapping[Tuple[str, str], float]",
        body_lines=[
            "    postlinks_df = table_data['PostLinks'].copy()",
            "    posts_df = table_data['Posts']",
            "    ",
            "    # Get percentage for this corruption",
            "    percentage = percentage_per_column.get(('PostLinks', 'PostId'), 0.1) if isinstance(percentage_per_column, dict) else 0.1",
            "    ",
            "    # Sample posts to create self-links",
            "    if len(posts_df) > 0:",
            "        n_corrupt = max(1, int(len(posts_df) * percentage))",
            "        posts_to_corrupt = posts_df.sample(n=min(n_corrupt, len(posts_df)), random_state=rand.randint(0, 2**32-1))",
            "        ",
            "        new_links = []",
            "        max_link_id = postlinks_df['Id'].max() if 'Id' in postlinks_df.columns else 0",
            "        ",
            "        for idx, post in posts_to_corrupt.iterrows():",
            "            # Create a self-link",
            "            new_link = {",
            "                'Id': max_link_id + len(new_links) + 1,",
            "                'PostId': post['Id'],",
            "                'RelatedPostId': post['Id'],  # Self-reference",
            "                'LinkTypeId': rand.choice([1, 3]),  # 1=Linked, 3=Duplicate",
            "                'CreationDate': pd.to_datetime(post['CreationDate']) + pd.Timedelta(days=rand.randint(1, 30))",
            "            }",
            "            # Add other columns with default values if they exist",
            "            for col in postlinks_df.columns:",
            "                if col not in new_link:",
            "                    new_link[col] = None",
            "            new_links.append(new_link)",
            "        ",
            "        if new_links:",
            "            new_links_df = pd.DataFrame(new_links)",
            "            postlinks_df = pd.concat([postlinks_df, new_links_df], ignore_index=True)",
            "            print(f'Created {len(new_links)} self-referencing post links')",
            "    ",
            "    table_data['PostLinks'] = postlinks_df",
            "    return table_data",
        ],
        return_statement="table_data",
        scope=[("PostLinks", "PostId"), ("PostLinks", "RelatedPostId")],
    )

    return corruptors


def create_manual_checks() -> Dict[str, CheckLogic]:
    """Create manually defined checks for benchmark ground truth.

    Returns:
        Dictionary of check name to CheckLogic instances
    """
    checks = {}

    # 1. Check that regular posts don't have more than 5 tags
    checks["check_posts_max_tags"] = CheckLogic(
        function_name="check_posts_max_tags",
        description="Check that regular posts (PostTypeId=1) don't have more than 5 tags",
        parameters="tables: Mapping[str, pd.DataFrame]",
        body_lines=[
            "    posts_df = tables['Posts']",
            "    result = {}",
            "    ",
            "    # Find regular posts with tags",
            "    regular_posts = posts_df[(posts_df['PostTypeId'] == 1) & (posts_df['Tags'].notna())]",
            "    ",
            "    violation_indices = []",
            "    for idx, row in regular_posts.iterrows():",
            "        tags = str(row['Tags'])",
            "        # Count tags",
            "        import re",
            "        tag_pattern = r'<([^<>]+)>'",
            "        tag_matches = re.findall(tag_pattern, tags)",
            "        if len(tag_matches) > 5:",
            "            violation_indices.append(idx)",
            "    ",
            "    if violation_indices:",
            "        violation_series = pd.Series(",
            "            violation_indices,",
            "            name='Tags'",
            "        )",
            "        result['Posts'] = violation_series",
        ],
        return_statement="result",
        scope=[("Posts", "Tags"), ("Posts", "PostTypeId")],
    )

    # 2. Check that answers don't have tags
    checks["check_answers_no_tags"] = CheckLogic(
        function_name="check_answers_no_tags",
        description="Check that answer posts (PostTypeId=2) don't have tags",
        parameters="tables: Mapping[str, pd.DataFrame]",
        body_lines=[
            "    posts_df = tables['Posts']",
            "    result = {}",
            "    ",
            "    # Find answers with tags (violation)",
            "    answers_with_tags = posts_df[",
            "        (posts_df['PostTypeId'] == 2) & ",
            "        (posts_df['Tags'].notna()) & ",
            "        (posts_df['Tags'] != '')",
            "    ]",
            "    ",
            "    if not answers_with_tags.empty:",
            "        violation_series = pd.Series(",
            "            answers_with_tags.index.tolist(),",
            "            name='Tags'",
            "        )",
            "        result['Posts'] = violation_series",
        ],
        return_statement="result",
        scope=[("Posts", "Tags"), ("Posts", "PostTypeId")],
    )

    # 3. Check for self-voting
    checks["check_no_self_voting"] = CheckLogic(
        function_name="check_no_self_voting",
        description="Check that users don't vote for their own posts",
        parameters="tables: Mapping[str, pd.DataFrame]",
        body_lines=[
            "    votes_df = tables['Votes']",
            "    posts_df = tables['Posts']",
            "    result = {}",
            "    ",
            "    # Preserve votes index",
            "    votes_with_index = votes_df.copy()",
            "    votes_with_index['original_index'] = votes_with_index.index",
            "    ",
            "    # Merge votes with posts to get OwnerUserId",
            "    merged = votes_with_index.merge(",
            "        posts_df[['Id', 'OwnerUserId']],",
            "        left_on='PostId',",
            "        right_on='Id',",
            "        how='left'",
            "    )",
            "    merged.set_index('original_index', inplace=True)",
            "    ",
            "    # Find self-votes",
            "    self_votes = merged[",
            "        (merged['UserId'].notna()) & ",
            "        (merged['OwnerUserId'].notna()) & ",
            "        (merged['UserId'] == merged['OwnerUserId'])",
            "    ]",
            "    ",
            "    if not self_votes.empty:",
            "        violation_series = pd.Series(",
            "            self_votes.index.tolist(),",
            "            name='Id'",
            "        )",
            "        result['Votes'] = violation_series",
        ],
        return_statement="result",
        scope=[("Votes", "UserId"), ("Votes", "PostId"), ("Posts", "OwnerUserId")],
    )

    # 4. Check for self-linking posts
    checks["check_no_self_links"] = CheckLogic(
        function_name="check_no_self_links",
        description="Check that posts don't link to themselves",
        parameters="tables: Mapping[str, pd.DataFrame]",
        body_lines=[
            "    postlinks_df = tables['PostLinks']",
            "    result = {}",
            "    ",
            "    # Find self-links",
            "    self_links = postlinks_df[",
            "        (postlinks_df['PostId'].notna()) & ",
            "        (postlinks_df['RelatedPostId'].notna()) & ",
            "        (postlinks_df['PostId'] == postlinks_df['RelatedPostId'])",
            "    ]",
            "    ",
            "    if not self_links.empty:",
            "        violation_series = pd.Series(",
            "            self_links.index.tolist(),",
            "            name='PostId'",
            "        )",
            "        result['PostLinks'] = violation_series",
        ],
        return_statement="result",
        scope=[("PostLinks", "PostId"), ("PostLinks", "RelatedPostId")],
    )

    return checks


def main():
    """Main entry point for benchmark generation."""
    # Fixed parameters
    database_name = "rel-stack"  # RelBench database name for Stack Exchange
    output_dir = "data/benchmark/rel_stack_4_corruptors"
    corruption_rate = 0.10  # 10% corruption rate
    seed = 42
    verbose = True

    # Configure logging
    log_level = "DEBUG" if verbose else "INFO"
    logger.remove()
    logger.add(sys.stderr, level=log_level)

    logger.info("RelStack Benchmark Generator")
    logger.info(f"RelBench database: {database_name}")
    logger.info(f"Output directory: {output_dir}")
    logger.info(f"Corruption rate: {corruption_rate}")
    logger.info(f"Random seed: {seed}")

    # Create output directory
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    # Initialize database
    logger.info("Initializing RelStack database...")
    db = RelStack(database_id="rel_stack_benchmark")

    # Load clean data from RelBench
    logger.info(f"Loading data from RelBench database: {database_name}...")

    try:
        db.load_table_data_from_relbench(database_name)

        # Count loaded tables
        loaded_count = len([name for name in db.table_data.keys() if not db.table_data[name].empty])
        logger.info(f"Loaded {loaded_count} tables from RelBench")

        # Log table statistics
        for table_name, df in db.table_data.items():
            logger.debug(f"Table {table_name}: {len(df)} rows, {len(df.columns)} columns")
    except Exception as e:
        logger.error(f"Failed to load data from RelBench: {e}")
        raise

    # Create and apply corruptors
    logger.info("Creating manual corruptors...")
    corruptors = create_manual_corruptors()
    logger.info(f"Created {len(corruptors)} corruptors")

    # Add corruptors to database
    for name, corruptor in corruptors.items():
        db.add_corruptors({name: corruptor})

    # Apply corruptions
    logger.info("Applying corruptions...")
    import random

    rand_gen = random.Random(seed)
    corruption_summary = []

    # Apply each corruptor with 10% corruption rate
    for corruptor_name in corruptors.keys():
        logger.debug(f"Applying corruptor: {corruptor_name}")

        # Apply corruption with specified rate (10%)
        result = db.corrupt(corruptor_name=corruptor_name, percentage=corruption_rate, rand=rand_gen)

        corruption_summary.append(
            {"corruptor": corruptor_name, "rate": corruption_rate, "tables_affected": list(result.keys())}
        )

    # Create and add checks
    logger.info("Creating manual checks...")
    checks = create_manual_checks()
    logger.info(f"Created {len(checks)} checks")

    # Add checks to database
    for name, check in checks.items():
        db.add_checks({name: check})

    # Run validation
    logger.info("Running validation checks...")
    validation_results = db.validate()

    # Separate violations from exceptions
    violations_dict = {k: v for k, v in validation_results.items() if isinstance(v, pd.DataFrame)}
    exceptions_dict = {k: v for k, v in validation_results.items() if isinstance(v, Exception)}

    # Log any check failures
    if exceptions_dict:
        logger.warning(f"{len(exceptions_dict)} checks failed with exceptions")
        for check_name, exc in exceptions_dict.items():
            logger.debug(f"Check '{check_name}' failed: {exc}")

    # Prepare validation summary
    validation_summary = {}
    total_violations = 0

    for check_name, violations_df in violations_dict.items():
        validation_summary[check_name] = {
            "violation_count": len(violations_df),
            "sample_violations": violations_df.head(5).to_dict("records") if not violations_df.empty else [],
        }
        total_violations += len(violations_df)

    logger.info(f"Total violations detected: {total_violations}")

    # Export results
    logger.info(f"Exporting benchmark data to {output_path}...")

    # 1. Export corrupted database
    corrupted_dir = output_path / "corrupted_data"
    db.export(directory=str(corrupted_dir), override_existing_files=True)

    # 2. Export validation results
    logger.info("Exporting validation results...")
    db.export_validation_result(directory=str(corrupted_dir), override_existing_files=True)

    # 3. Create metadata file
    metadata = {
        "generation_timestamp": datetime.now().isoformat(),
        "configuration": {"database_name": database_name, "corruption_rate": corruption_rate, "random_seed": seed},
        "statistics": {
            "tables_loaded": loaded_count,
            "corruptors_applied": len(corruptors),
            "checks_executed": len(checks),
            "total_violations": total_violations,
        },
        "corruption_summary": corruption_summary,
        "validation_summary": validation_summary,
        "corruptors": {name: {"description": c.description, "scope": c.scope} for name, c in corruptors.items()},
        "checks": {name: {"description": c.description, "scope": c.scope} for name, c in checks.items()},
    }

    with open(output_path / "benchmark_metadata.json", "w") as f:
        json.dump(metadata, f, indent=2)

    logger.success(f"Benchmark data generated successfully at {output_path}")

    # Print summary
    print("\n" + "=" * 60)
    print("BENCHMARK GENERATION SUMMARY")
    print("=" * 60)
    print(f"Tables processed: {loaded_count}")
    print(f"Corruptors applied: {len(corruptors)}")
    print(f"Checks executed: {len(checks)}")
    print(f"Total violations: {total_violations}")
    print("\nViolations by check:")
    for check_name, summary in validation_summary.items():
        print(f"  - {check_name}: {summary['violation_count']} violations")
    print("\nOutput directory structure:")
    print(f"  {output_path}/")
    print(f"    ├── corrupted_data/      # Data after corruption")
    print(f"    ├── violations.csv       # All check violations concatenated")
    print(f"    └── benchmark_metadata.json  # Generation metadata")

    return 0


if __name__ == "__main__":
    sys.exit(main())
