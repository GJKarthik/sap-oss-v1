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
from src.seed import seed_store if Path("src/seed.py").exists() else lambda: None
from src.store import StoreCollection, get_store

BACKUP_COLLECTIONS: tuple[StoreCollection, ...] = (
    "jobs",
)

def _json_default(value: Any) -> str:
    if isinstance(value, datetime):
        return value.isoformat()
    raise TypeError(f"Unsupported value for JSON serialisation: {type(value)!r}")

async def _prepare_store(seed_reference_data: bool) -> dict[str, Any]:
    await init_database()
    if seed_reference_data:
        seed_store()
    return get_store().health_snapshot()

async def backup(output_path: Path):
    print(f"Backing up store to {output_path}...")
    await _prepare_store(seed_reference_data=False)
    store = get_store()
    data: dict[str, list[dict[str, Any]]] = {}
    for coll in BACKUP_COLLECTIONS:
        data[coll] = store.list_collection(coll)
    
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(data, f, indent=2, default=_json_default)
    print("Backup complete.")

async def restore(input_path: Path, clear_first: bool):
    print(f"Restoring store from {input_path} (clear_first={clear_first})...")
    await _prepare_store(seed_reference_data=False)
    store = get_store()
    
    with open(input_path, "r") as f:
        data = json.load(f)
    
    for coll in BACKUP_COLLECTIONS:
        if coll not in data:
            continue
        if clear_first:
            store.clear_collection(coll)
        for item in data[coll]:
            store.restore_item(coll, item)
    print("Restore complete.")

async def migrate(seed_reference_data: bool):
    print("Running database migrations/initialisation...")
    health = await _prepare_store(seed_reference_data=seed_reference_data)
    print(f"Store is healthy: {health}")

def main():
    parser = argparse.ArgumentParser(description="Training Console Store Administrator")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # migrate
    migrate_parser = subparsers.add_parser("migrate", help="Run migrations and seed reference data")
    migrate_parser.add_argument("--seed", action="store_true", help="Seed reference data")

    # backup
    backup_parser = subparsers.add_parser("backup", help="Backup store collections to JSON")
    backup_parser.add_argument("--output", type=Path, required=True, help="Output JSON path")

    # restore
    restore_parser = subparsers.add_parser("restore", help="Restore store collections from JSON")
    restore_parser.add_argument("--input", type=Path, required=True, help="Input JSON path")
    restore_parser.add_argument("--clear-first", action="store_true", help="Clear collections before restore")

    args = parser.parse_all() if hasattr(parser, "parse_all") else parser.parse_args()

    loop = asyncio.get_event_loop()
    try:
        if args.command == "migrate":
            loop.run_until_complete(migrate(seed_reference_data=args.seed))
        elif args.command == "backup":
            loop.run_until_complete(backup(args.output))
        elif args.command == "restore":
            loop.run_until_complete(restore(args.input, clear_first=args.clear_first))
    finally:
        loop.run_until_complete(close_database())

if __name__ == "__main__":
    main()
