# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
HippoCPP Table Module for Mojo

Provides table type definitions for the graph database:
- Column: Individual column metadata
- Table: Base table structure
- NodeTable: Node table with primary key support
- RelTable: Relationship table with source/destination tracking
"""

from collections import Dict, List


# ============================================================================
# Column Definition
# ============================================================================

@value
struct Column:
    """Column metadata and definition"""
    var name: String
    var data_type: Int  # LogicalType value
    var column_id: UInt32
    var is_primary_key: Bool
    var is_nullable: Bool
    var default_value: String

    fn __init__(inout self, name: String, data_type: Int, column_id: UInt32):
        self.name = name
        self.data_type = data_type
        self.column_id = column_id
        self.is_primary_key = False
        self.is_nullable = True
        self.default_value = ""

    @staticmethod
    fn primary_key(name: String, data_type: Int, column_id: UInt32) -> Column:
        """Create a primary key column"""
        var col = Column(name, data_type, column_id)
        col.is_primary_key = True
        col.is_nullable = False
        return col


# ============================================================================
# Table Base Structure
# ============================================================================

struct Table:
    """Base table structure for graph database"""
    var name: String
    var table_id: UInt64
    var columns: List[Column]
    var row_count: UInt64

    fn __init__(inout self, name: String, table_id: UInt64):
        self.name = name
        self.table_id = table_id
        self.columns = List[Column]()
        self.row_count = 0

    fn add_column(inout self, column: Column):
        """Add a column to the table"""
        self.columns.append(column)

    fn get_column_by_name(self, name: String) -> Column:
        """Get column by name, returns empty column if not found"""
        for col in self.columns:
            if col[].name == name:
                return col[]
        return Column("", 0, 0)

    fn get_num_columns(self) -> Int:
        """Get the number of columns"""
        return len(self.columns)

    fn increment_row_count(inout self):
        """Increment row count"""
        self.row_count += 1


# ============================================================================
# Node Table Structure
# ============================================================================

struct NodeTable:
    """Node table with primary key support"""
    var base: Table
    var primary_key_column_idx: Int
    var has_serial_pk: Bool

    fn __init__(inout self, name: String, table_id: UInt64):
        self.base = Table(name, table_id)
        self.primary_key_column_idx = -1
        self.has_serial_pk = False

    fn add_column(inout self, column: Column):
        """Add a column to the node table"""
        if column.is_primary_key:
            self.primary_key_column_idx = len(self.base.columns)
        self.base.add_column(column)

    fn get_primary_key_column(self) -> Column:
        """Get the primary key column"""
        if self.primary_key_column_idx >= 0 and self.primary_key_column_idx < len(self.base.columns):
            return self.base.columns[self.primary_key_column_idx]
        return Column("", 0, 0)

    fn get_name(self) -> String:
        """Get table name"""
        return self.base.name

    fn get_table_id(self) -> UInt64:
        """Get table ID"""
        return self.base.table_id


# ============================================================================
# Relationship Table Structure
# ============================================================================

struct RelTable:
    """Relationship table with source and destination tracking"""
    var base: Table
    var src_table_id: UInt64
    var dst_table_id: UInt64
    var multiplicity: String

    fn __init__(inout self, name: String, table_id: UInt64, src_id: UInt64, dst_id: UInt64):
        self.base = Table(name, table_id)
        self.src_table_id = src_id
        self.dst_table_id = dst_id
        self.multiplicity = "ONE_TO_MANY"

    fn add_column(inout self, column: Column):
        """Add a column to the relationship table"""
        self.base.add_column(column)

    fn set_multiplicity(inout self, mult: String):
        """Set the relationship multiplicity"""
        self.multiplicity = mult

    fn get_name(self) -> String:
        """Get table name"""
        return self.base.name

    fn get_table_id(self) -> UInt64:
        """Get table ID"""
        return self.base.table_id


# ============================================================================
# Tests
# ============================================================================

fn test_column():
    """Test Column"""
    let col = Column("name", 11, 0)  # 11 = STRING type
    assert_equal(col.name, "name")
    assert_equal(col.column_id, 0)
    assert_true(not col.is_primary_key)
    assert_true(col.is_nullable)

    let pk = Column.primary_key("id", 4, 0)  # 4 = INT64 type
    assert_true(pk.is_primary_key)
    assert_true(not pk.is_nullable)
    print("✓ Column tests passed")


fn test_table():
    """Test Table"""
    var table = Table("Person", 1)
    assert_equal(table.name, "Person")
    assert_equal(table.table_id, 1)
    assert_equal(table.row_count, 0)

    let id_col = Column.primary_key("id", 4, 0)
    table.add_column(id_col)

    let name_col = Column("name", 11, 1)
    table.add_column(name_col)

    assert_equal(table.get_num_columns(), 2)

    let found = table.get_column_by_name("name")
    assert_equal(found.name, "name")
    print("✓ Table tests passed")


fn test_node_table():
    """Test NodeTable"""
    var node_table = NodeTable("Person", 1)
    assert_equal(node_table.get_name(), "Person")
    assert_equal(node_table.get_table_id(), 1)

    let id_col = Column.primary_key("id", 4, 0)
    node_table.add_column(id_col)

    let name_col = Column("name", 11, 1)
    node_table.add_column(name_col)

    assert_equal(node_table.primary_key_column_idx, 0)

    let pk = node_table.get_primary_key_column()
    assert_equal(pk.name, "id")
    print("✓ NodeTable tests passed")


fn test_rel_table():
    """Test RelTable"""
    var rel_table = RelTable("WORKS_FOR", 2, 1, 3)
    assert_equal(rel_table.get_name(), "WORKS_FOR")
    assert_equal(rel_table.src_table_id, 1)
    assert_equal(rel_table.dst_table_id, 3)

    let src_col = Column("src_id", 4, 0)
    rel_table.add_column(src_col)

    let dst_col = Column("dst_id", 4, 1)
    rel_table.add_column(dst_col)

    rel_table.set_multiplicity("MANY_TO_MANY")
    assert_equal(rel_table.multiplicity, "MANY_TO_MANY")
    print("✓ RelTable tests passed")


fn main():
    """Run all tests"""
    print("Running Mojo table module tests...")
    test_column()
    test_table()
    test_node_table()
    test_rel_table()
    print("All tests passed! ✓")
