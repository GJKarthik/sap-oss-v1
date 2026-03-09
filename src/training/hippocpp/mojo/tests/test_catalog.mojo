# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Tests for the HippoCPP Catalog Module."""


fn test_table_type():
    """Test TableType enumeration."""
    from catalog import TableType

    let node = TableType.NODE
    let rel = TableType.REL
    assert_true(node != rel)
    assert_true(node == TableType.NODE)
    print("✓ TableType tests passed")


fn test_property_creation():
    """Test Property creation and primary key factory."""
    from catalog import Property
    from common import LogicalType

    let prop = Property("age", LogicalType.INT32, 1)
    assert_equal(prop.name, "age")
    assert_true(not prop.is_primary_key)
    assert_true(prop.is_nullable)

    let pk = Property.primary_key("id", LogicalType.INT64, 0)
    assert_true(pk.is_primary_key)
    assert_true(not pk.is_nullable)
    print("✓ Property creation tests passed")


fn test_table_schema_operations():
    """Test TableSchema add/get operations."""
    from catalog import TableSchema, TableType, Property
    from common import LogicalType

    var schema = TableSchema("Person", 1, TableType.NODE)

    let pk = Property.primary_key("id", LogicalType.INT64, 0)
    schema.add_property(pk)

    let name = Property("name", LogicalType.STRING, 1)
    schema.add_property(name)

    let age = Property("age", LogicalType.INT32, 2)
    schema.add_property(age)

    assert_equal(schema.get_num_properties(), 3)
    assert_true(schema.is_node_table())
    assert_true(not schema.is_rel_table())

    let found = schema.get_property_by_name("name")
    assert_equal(found.name, "name")

    let by_id = schema.get_property_by_id(2)
    assert_equal(by_id.name, "age")

    let primary = schema.get_primary_key()
    assert_equal(primary.name, "id")
    print("✓ TableSchema operations tests passed")


fn test_catalog_create_tables():
    """Test Catalog table creation."""
    from catalog import Catalog
    from common import LogicalType

    var catalog = Catalog("test_db")

    let person_id = catalog.create_node_table("Person")
    let company_id = catalog.create_node_table("Company")

    assert_equal(catalog.get_num_tables(), 2)
    assert_true(catalog.has_table("Person"))
    assert_true(catalog.has_table("Company"))
    assert_true(not catalog.has_table("Unknown"))
    print("✓ Catalog create tables tests passed")


fn test_catalog_properties():
    """Test Catalog property management."""
    from catalog import Catalog
    from common import LogicalType

    var catalog = Catalog("test_db")
    _ = catalog.create_node_table("Person")

    _ = catalog.add_primary_key("Person", "id", LogicalType.INT64)
    _ = catalog.add_property("Person", "name", LogicalType.STRING)
    _ = catalog.add_property("Person", "age", LogicalType.INT32)

    let schema = catalog.get_table_schema("Person")
    assert_equal(schema.get_num_properties(), 3)

    let pk = schema.get_primary_key()
    assert_equal(pk.name, "id")
    print("✓ Catalog properties tests passed")


fn test_catalog_relationships():
    """Test Catalog relationship table creation."""
    from catalog import Catalog
    from common import LogicalType

    var catalog = Catalog("test_db")

    _ = catalog.create_node_table("Person")
    _ = catalog.create_node_table("Company")
    _ = catalog.create_rel_table("WORKS_FOR", "Person", "Company")

    assert_equal(catalog.get_num_tables(), 3)
    assert_true(catalog.has_table("WORKS_FOR"))

    let node_names = catalog.get_node_table_names()
    assert_equal(len(node_names), 2)

    let rel_names = catalog.get_rel_table_names()
    assert_equal(len(rel_names), 1)
    print("✓ Catalog relationships tests passed")


fn test_catalog_drop_table():
    """Test Catalog table dropping."""
    from catalog import Catalog

    var catalog = Catalog("test_db")
    _ = catalog.create_node_table("Temp")
    assert_true(catalog.has_table("Temp"))

    let dropped = catalog.drop_table("Temp")
    assert_true(dropped)
    assert_true(not catalog.has_table("Temp"))
    assert_equal(catalog.get_num_tables(), 0)

    let not_found = catalog.drop_table("NonExistent")
    assert_true(not not_found)
    print("✓ Catalog drop table tests passed")


fn main():
    """Run all catalog tests."""
    print("Running catalog module tests...")
    test_table_type()
    test_property_creation()
    test_table_schema_operations()
    test_catalog_create_tables()
    test_catalog_properties()
    test_catalog_relationships()
    test_catalog_drop_table()
    print("All catalog tests passed! ✓")

