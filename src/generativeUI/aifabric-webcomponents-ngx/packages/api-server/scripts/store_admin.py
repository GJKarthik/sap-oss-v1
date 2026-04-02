#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
from datetime import datetime
from pathlib import Path
import sys
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from src.database import close_database, init_database
from src.seed import seed_store
from src.store import StoreCollection, get_store

BACKUP_COLLECTIONS: tuple[StoreCollection, ...] = (
    "users",
    "models",
    "deployments",
    "datasources",
    "vector_stores",
    "governance_rules",
)
COLLECTION_KEY_FIELDS: dict[StoreCollection, str] = {
    "users": "username",
    "models": "id",
    "deployments": "id",
    "datasources": "id",
    "vector_stores": "table_name",
    "governance_rules": "id",
}


def _json_default(value: Any) -> str:
    if isinstance(value, datetime):
        return value.isoformat()
    raise TypeError(f"Unsupported value for JSON serialisation: {type(value)!r}")


async def _prepare_store(seed_reference_data: bool) -> dict[str, Any]:
    await init_database()
    if seed_reference_data:
        seed_store()
    return get_store().health_snapshot()


async def _shutdown_store() -> None:
    await close_database()


def _backup_payload() -> dict[str, Any]:
    store = get_store()
    return {
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "store_backend": store.backend_name,
        "connection_target": store.connection_target,
        "collections": {
            name: store.list_records(name)
            for name in BACKUP_COLLECTIONS
        },
    }


def migrate_command(args: argparse.Namespace) -> int:
    snapshot = asyncio.run(_prepare_store(seed_reference_data=not args.skip_seed))
    asyncio.run(_shutdown_store())
    print(json.dumps({"status": "ok", "operation": "migrate", "store": snapshot}, default=_json_default))
    return 0


def backup_command(args: argparse.Namespace) -> int:
    asyncio.run(_prepare_store(seed_reference_data=False))
    payload = _backup_payload()
    output_path = Path(args.output).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2, default=_json_default) + "\n", encoding="utf-8")
    asyncio.run(_shutdown_store())
    print(json.dumps({"status": "ok", "operation": "backup", "output": str(output_path)}))
    return 0


def restore_command(args: argparse.Namespace) -> int:
    input_path = Path(args.input).resolve()
    payload = json.loads(input_path.read_text(encoding="utf-8"))
    asyncio.run(_prepare_store(seed_reference_data=False))
    store = get_store()
    if args.clear_first:
        store.clear()

    restored_counts: dict[str, int] = {}
    for collection_name in BACKUP_COLLECTIONS:
        records = payload.get("collections", {}).get(collection_name, [])
        key_field = COLLECTION_KEY_FIELDS[collection_name]
        restored = 0
        for record in records:
            record_key = record.get(key_field)
            if not record_key:
                raise ValueError(f"Backup record for {collection_name} is missing key field '{key_field}'")
            store.set_record(collection_name, str(record_key), record)
            restored += 1
        restored_counts[collection_name] = restored

    asyncio.run(_shutdown_store())
    print(
        json.dumps(
            {
                "status": "ok",
                "operation": "restore",
                "input": str(input_path),
                "restored_counts": restored_counts,
            }
        )
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Store operations for SAP AI Fabric Console")
    subparsers = parser.add_subparsers(dest="command", required=True)

    migrate_parser = subparsers.add_parser("migrate", help="Initialise the configured store backend")
    migrate_parser.add_argument("--skip-seed", action="store_true", help="Skip seed/bootstrap logic during migration")
    migrate_parser.set_defaults(func=migrate_command)

    backup_parser = subparsers.add_parser("backup", help="Export application data to a JSON snapshot")
    backup_parser.add_argument("--output", required=True, help="Path to write the backup snapshot JSON")
    backup_parser.set_defaults(func=backup_command)

    restore_parser = subparsers.add_parser("restore", help="Restore application data from a JSON snapshot")
    restore_parser.add_argument("--input", required=True, help="Path to the backup snapshot JSON")
    restore_parser.add_argument("--clear-first", action="store_true", help="Clear existing store records before restore")
    restore_parser.set_defaults(func=restore_command)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
