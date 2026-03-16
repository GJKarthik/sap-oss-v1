# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Utility functions for the HANA ML tools.
"""
import os
import shutil
import json
import re
import unicodedata
from pathlib import Path
import logging
from datetime import datetime, date
from typing import Union
from pandas import Timestamp
from numpy import int64
from hana_ml.model_storage import ModelStorage
#pylint: disable=too-many-nested-blocks, unexpected-keyword-arg, invalid-name

logger = logging.getLogger(__name__)

_IDENTIFIER_PATTERN = re.compile(r'^[A-Za-z0-9_]+$')
ALLOWED_SQL_PREFIXES = ('SELECT', 'WITH')
BLOCKED_SQL_KEYWORDS = ('DROP', 'DELETE', 'UPDATE', 'INSERT', 'ALTER', 'TRUNCATE')


def _validate_identifier(value: str, field_name: str) -> str:
    if not isinstance(value, str) or not _IDENTIFIER_PATTERN.fullmatch(value):
        raise ValueError(f'{field_name} must contain only letters, numbers, and underscores')
    return value


def _sanitize_select_statement(select_statement: str) -> str:
    statement = select_statement.strip()
    statement = re.sub(r'^```(?:sql)?\s*', '', statement, flags=re.IGNORECASE)
    statement = re.sub(r'\s*```$', '', statement).strip()

    for char in statement:
        if unicodedata.category(char).startswith('C') and char not in ('\t', '\n', '\r'):
            raise ValueError('Non-printable or format characters are not allowed in HANA ML SQL.')
    try:
        statement.encode('ascii')
    except UnicodeEncodeError as exc:
        raise ValueError('Only ASCII SQL statements are allowed in HANA ML tools.') from exc

    sql_match = re.search(r'\b(WITH|SELECT)\b.*', statement, re.DOTALL | re.IGNORECASE)
    if sql_match and statement[:sql_match.start()].strip():
        raise ValueError('Only raw SELECT or WITH SQL statements are allowed.')
    if not sql_match:
        raise ValueError('Failed to extract a valid read-only SQL statement.')

    statement = sql_match.group(0).strip()
    normalized_statement = re.sub(r'\s+', ' ', statement).upper()

    if not normalized_statement.startswith(ALLOWED_SQL_PREFIXES):
        raise ValueError('Only SELECT or WITH statements are allowed.')
    if ';' in statement:
        raise ValueError('Multiple SQL statements are not allowed.')
    if '--' in statement or '/*' in statement or '*/' in statement:
        raise ValueError('SQL comments are not allowed in HANA ML tools.')

    for keyword in BLOCKED_SQL_KEYWORDS:
        if re.search(rf'\b{keyword}\b', normalized_statement):
            raise ValueError(f'Dangerous SQL keyword is not allowed: {keyword}')

    return statement

def convert_cap_to_hdi(source_dir, target_dir, archive=True):
    """
    Convert a CAP project structure to an HDI structure.
    Parameters
    ----------
    source_dir : str
        The source directory containing the CAP project files.
    target_dir : str
        The target directory where the HDI structure will be created.
    archive : bool, optional
        If True, the function will create an archive of the source directory.
        Default is True.
    """
    target_path = Path(target_dir)
    if target_path.exists() and target_path.is_dir():
        if any(target_path.iterdir()):
            if archive:
                timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
                archive_path = f"archive_{target_dir}_{timestamp}.tar.gz"
                shutil.make_archive(archive_path, 'gztar', target_dir)
                # delete the target directory after archiving including subdirectories except the archive
                for item in target_path.iterdir():
                    if item.name != f"{target_dir}.tar.gz":
                        if item.is_dir():
                            shutil.rmtree(item)
                        else:
                            item.unlink()
                logger.info("Created archive: %s", archive_path)
            else:
                logger.info("Target directory %s already exists and is not empty.", target_dir)
                raise FileExistsError(f"The target_dir {target_dir} is not empty. Please provide an empty directory.")
    db_src = os.path.join(Path(target_dir), "db", "src")
    db_cfg = os.path.join(Path(target_dir), "db", "cfg")
    srv_dir = os.path.join(Path(target_dir), "srv")
    os.makedirs(db_src, exist_ok=True)
    os.makedirs(db_cfg, exist_ok=True)
    os.makedirs(srv_dir, exist_ok=True)
    cap_db = Path(os.path.join(Path(source_dir), "db"))
    src_files = Path(os.path.join(cap_db, "src")).glob("*")
    for file in src_files:
        if file.suffix == ".cds":
            target_file = os.path.join(db_src, f"{file.stem}.hdbcds")
            shutil.copy2(file, target_file)
        else:
            shutil.copy2(file, os.path.join(db_src, file.name))
    for cds_file in cap_db.glob("*.cds"):
        target_file = os.path.join(db_src, f"{cds_file.stem}.hdbcds")
        shutil.copy2(cds_file, target_file)
    srv_source = Path(os.path.join(Path(source_dir), "srv"))
    if srv_source.exists():
        shutil.copytree(srv_source, srv_dir, dirs_exist_ok=True)
    hdi_config = os.path.join(db_cfg, ".hdiconfig")
    with open(hdi_config, "w") as f:
        json.dump({
            "file": {
                "path": os.path.join("db", "src"),
                "build_plugins": [
                    {"plugin": "com.sap.hana.di.cds"},
                    {"plugin": "com.sap.hana.di.procedure"},
                    {"plugin": "com.sap.hana.di.synonym"},
                    {"plugin": "com.sap.hana.di.grant"}
                ]
            }
        }, f, indent=2)

class _CustomEncoder(json.JSONEncoder):
    """
    This class is used to encode the model attributes into JSON string.
    """
    def default(self, obj): #pylint: disable=arguments-renamed
        if isinstance(obj, (Timestamp, datetime, date)):
            # Convert Timestamp, datetime or date to ISO string
            return obj.isoformat()
        elif isinstance(obj, (int64, int)):
            # Convert numpy int64 or Python int to Python int
            return int(obj)
        # Let other types use the default handler
        return super().default(obj)


def add_stopping_hint(x : str):
    """Added the hint for stopping the execution when an error message is returned."""
    return (x + ". Please stop the execution and return.").replace("..", ".")

def generate_model_storage_version(ms : ModelStorage, version: Union[int, str, None], name: str) -> int:
    """Generate the model storage version."""
    ms._create_metadata_table()
    if version is None:
        version = ms._get_new_version_no(name)
        if version is None:
            version = 1
        else:
            version = int(version)
    return version

def _create_temp_table(conn, select_statement: str, tool_name: str, additional_info: str = None) -> str:
    """
    Create a temporary table in the HANA database.
    Parameters
    ----------
    conn : Connection
        The HANA connection object.
    select_statement : str
        The SQL select statement to create the temporary table.
    tool_name : str
        The name of the tool to create a unique temporary table name.
    additional_info : str, optional
        Additional information to append to the table name.
    Returns
    -------
    str
        The SQL statement to select from the temporary table.
    """
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S%f")
    if additional_info:
        additional_info = f"_{additional_info}_"
    else:
        additional_info = "_"
    table_name_body = _validate_identifier(f"{tool_name}{additional_info}{timestamp}".upper(), 'table_name')
    safe_table_name = f"#{table_name_body}"
    sanitized_select_statement = _sanitize_select_statement(select_statement)
    create_temp_table_sql = f"CREATE LOCAL TEMPORARY TABLE {safe_table_name} AS ({sanitized_select_statement})"
    conn.execute_sql(create_temp_table_sql)
    return f"SELECT * FROM {safe_table_name}"
