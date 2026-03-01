# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
import pandas as pd
import pandera.pandas as pa
from typing import Any
from definition.base.table import Table
from definition.base.database import Database


# --- User Table -----------------------------------------------------------------------


class Users(Table, primary_keys=["Id"]):
    """Users — Stack Overflow user accounts."""

    Id: int = pa.Field(nullable=False)  # User ID (Int64)
    AccountId: float = pa.Field(nullable=True)  # Account ID (0.0% null)
    DisplayName: str = pa.Field(nullable=True)  # Display name (0.0% null)
    Location: str = pa.Field(nullable=True)  # User location (72.1% null)
    ProfileImageUrl: float = pa.Field(nullable=True)  # Profile image URL (100% null)
    WebsiteUrl: str = pa.Field(nullable=True)  # Website URL (88.9% null)
    AboutMe: str = pa.Field(nullable=True)  # About me text (80.5% null)
    CreationDate: Any = pa.Field(nullable=False)  # Creation date (datetime)


# --- Posts Table ----------------------------------------------------------------------


class Posts(
    Table,
    primary_keys=["Id"],
    foreign_keys={"OwnerUserId": ("Users", "Id"), "ParentId": ("Posts", "Id"), "AcceptedAnswerId": ("Posts", "Id")},
):
    """Posts — Questions and answers on Stack Overflow."""

    Id: int = pa.Field(nullable=False)  # Post ID (Int64)
    OwnerUserId: int = pa.Field(nullable=True)  # Owner user ID (1.6% null)
    PostTypeId: int = pa.Field(nullable=False)  # Post type (1=Question, 2=Answer)
    AcceptedAnswerId: int = pa.Field(nullable=True)  # Accepted answer ID (82.7% null)
    ParentId: int = pa.Field(nullable=True)  # Parent post ID (49.9% null)
    OwnerDisplayName: str = pa.Field(nullable=True)  # Owner display name (97.4% null)
    Title: str = pa.Field(nullable=True)  # Post title (51.0% null)
    Tags: str = pa.Field(nullable=True)  # Tags (XML format, 51.0% null)
    ContentLicense: str = pa.Field(nullable=False)  # Content license
    Body: str = pa.Field(nullable=True)  # Post body (0.1% null)
    CreationDate: Any = pa.Field(nullable=False)  # Creation date (datetime)


# --- Badges Table ---------------------------------------------------------------------


class Badges(Table, primary_keys=["Id"], foreign_keys={"UserId": ("Users", "Id")}):
    """Badges — User badges earned on Stack Overflow."""

    Id: int = pa.Field(nullable=False)  # Badge ID (Int64)
    UserId: int = pa.Field(nullable=False)  # User ID (NO NULLS)
    Class: int = pa.Field(nullable=False)  # Badge class
    Name: str = pa.Field(nullable=False)  # Badge name
    TagBased: bool = pa.Field(nullable=False)  # Tag-based badge
    Date: Any = pa.Field(nullable=False)  # Date earned (datetime)


# --- Post History Table --------------------------------------------------------------


class PostHistory(Table, primary_keys=["Id"], foreign_keys={"PostId": ("Posts", "Id"), "UserId": ("Users", "Id")}):
    """PostHistory — Edit history of posts."""

    Id: int = pa.Field(nullable=False)  # History ID (Int64)
    PostId: int = pa.Field(nullable=False)  # Post ID (NO NULLS)
    UserId: int = pa.Field(nullable=True)  # User ID (6.4% null)
    PostHistoryTypeId: int = pa.Field(nullable=False)  # History type ID
    UserDisplayName: str = pa.Field(nullable=True)  # User display name (97.9% null)
    ContentLicense: str = pa.Field(nullable=True)  # Content license (9.5% null)
    RevisionGUID: str = pa.Field(nullable=False)  # Revision GUID
    Text: str = pa.Field(nullable=True)  # Text content (9.8% null)
    Comment: str = pa.Field(nullable=True)  # Comment (60.8% null)
    CreationDate: Any = pa.Field(nullable=False)  # Creation date (datetime)


# --- Comments Table -------------------------------------------------------------------


class Comments(Table, primary_keys=["Id"], foreign_keys={"UserId": ("Users", "Id"), "PostId": ("Posts", "Id")}):
    """Comments — Comments on posts."""

    Id: int = pa.Field(nullable=False)  # Comment ID (Int64)
    PostId: int = pa.Field(nullable=True)  # Post ID (0.0% null)
    UserId: int = pa.Field(nullable=True)  # User ID (1.9% null)
    ContentLicense: str = pa.Field(nullable=False)  # Content license
    UserDisplayName: str = pa.Field(nullable=True)  # User display name (98.1% null)
    Text: str = pa.Field(nullable=False)  # Comment text
    CreationDate: Any = pa.Field(nullable=False)  # Creation date (datetime)


# --- Votes Table ----------------------------------------------------------------------


class Votes(Table, primary_keys=["Id"], foreign_keys={"PostId": ("Posts", "Id"), "UserId": ("Users", "Id")}):
    """Votes — Votes on posts."""

    Id: int = pa.Field(nullable=False)  # Vote ID (Int64)
    UserId: int = pa.Field(nullable=True)  # User ID (99.6% null)
    PostId: int = pa.Field(nullable=True)  # Post ID (9.0% null)
    VoteTypeId: int = pa.Field(nullable=False)  # Vote type ID
    CreationDate: Any = pa.Field(nullable=False)  # Creation date (datetime)


# --- Post Links Table -----------------------------------------------------------------


class PostLinks(Table, primary_keys=["Id"], foreign_keys={"PostId": ("Posts", "Id"), "RelatedPostId": ("Posts", "Id")}):
    """PostLinks — Links between related posts."""

    Id: int = pa.Field(nullable=False)  # Link ID (Int64)
    PostId: int = pa.Field(nullable=True)  # Post ID (20.9% null)
    RelatedPostId: int = pa.Field(nullable=True)  # Related post ID (2.3% null)
    LinkTypeId: int = pa.Field(nullable=False)  # Link type ID
    CreationDate: Any = pa.Field(nullable=False)  # Creation date (datetime)


# --- Database container ---------------------------------------------------------------


class RelStack(Database):
    """Stack Overflow database from RelBench rel-stack dataset."""

    def __init__(self, database_id: str = "rel_stack", **kwargs):
        super().__init__(database_id=database_id, **kwargs)
        self.create_table("Users", Users)
        self.create_table("Posts", Posts)
        self.create_table("Badges", Badges)
        self.create_table("PostHistory", PostHistory)
        self.create_table("Comments", Comments)
        self.create_table("Votes", Votes)
        self.create_table("PostLinks", PostLinks)
        self.derive_rule_based_checks()


# --- Demo loader/validator ------------------------------------------------------------

if __name__ == "__main__":
    from relbench.datasets import get_dataset

    print("🏗️ Loading Stack Overflow Database from RelBench...")

    # Load the RelBench dataset
    dataset = get_dataset("rel-stack")
    db_relbench = dataset.get_db()

    # Create our database schema
    db = RelStack("rel_stack")

    # Load data from RelBench into our schema
    loaded = 0
    for table_name in db_relbench.table_dict.keys():
        try:
            # Get the DataFrame from RelBench
            df = db_relbench.table_dict[table_name].df

            # Map RelBench table names to our class names
            table_mapping = {
                "users": "Users",
                "posts": "Posts",
                "badges": "Badges",
                "postHistory": "PostHistory",
                "comments": "Comments",
                "votes": "Votes",
                "postLinks": "PostLinks",
            }

            if table_name in table_mapping:
                our_table_name = table_mapping[table_name]
                # Use the set_table_data method
                db.set_table_data(our_table_name, df)
                print(f"✅ Loaded {our_table_name} with {len(df)} rows")
                loaded += 1
        except Exception as e:
            print(f"⚠️ Failed to load {table_name}: {e}")

    print(f"✅ Tables loaded: {loaded}")

    # Validate the loaded data
    print("\n🔍 Validating data...")
    results = db.validate()

    # Separate violations and exceptions
    violations = {k: v for k, v in results.items() if isinstance(v, pd.DataFrame) and not v.empty}
    exceptions = {k: v for k, v in results.items() if isinstance(v, Exception)}

    # Print validation results
    print("\n📊 Validation Results:")
    print("=" * 60)

    # Print violations summary
    if violations:
        print(f"\n✗ Found {len(violations)} checks with violations:")
        total_violations = 0
        for check_name, df in violations.items():
            violation_count = len(df)
            total_violations += violation_count
            print(f"  - {check_name}: {violation_count} violations")

            # Show sample violations (first 3)
            if violation_count > 0:
                print(f"    Sample violations (showing up to 3):")
                sample_df = df.head(3)
                for idx, row in sample_df.iterrows():
                    # Show key fields from the violation
                    table = row.get("table_name", "N/A")
                    column = row.get("column", "N/A")
                    failure = row.get("failure_case", "N/A")
                    print(f"      • Table: {table}, Column: {column}, Value: {failure}")

        print(f"\n📈 Total violations across all checks: {total_violations}")
    else:
        print("\n✓ No violations found - all checks passed!")

    # Print exceptions summary
    if exceptions:
        print(f"\n⚠️ Found {len(exceptions)} checks that failed with errors:")
        for check_name, exc in exceptions.items():
            exc_type = type(exc).__name__
            exc_msg = str(exc)
            # Truncate long error messages
            if len(exc_msg) > 100:
                exc_msg = exc_msg[:100] + "..."
            print(f"  - {check_name}: {exc_type} - {exc_msg}")
    else:
        print("\n✓ All checks executed successfully without errors!")

    print("\n" + "=" * 60)
    print(
        f"Summary: {loaded} tables loaded, {len(violations)} checks with violations, {len(exceptions)} checks with errors"
    )
