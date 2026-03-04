# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
HippoCPP - Graph Database Engine for Mojo

A high-performance graph database implementation providing:
- Embedded graph storage (no server required)
- HNSW vector index for similarity search
- Cypher query language support
- Full-text search
- MVCC transaction support

Example:
    var db = HippoDB("./data/mydb")
    db.execute("CREATE (n:Person {name: 'Alice'})")
    var result = db.execute("MATCH (n:Person) RETURN n.name")
"""

from .storage import StorageManager, PageManager, FileHandle, DatabaseHeader
from .table import Table, NodeTable, RelTable, Column
from .buffer_manager import BufferManager, BufferFrame
from .index import HashIndex, HNSWIndex