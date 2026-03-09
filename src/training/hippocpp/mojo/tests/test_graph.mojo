# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Tests for the HippoCPP Graph Module."""


fn test_property_value_types():
    """Test PropertyValue type constructors."""
    from graph import PropertyValue

    let null_val = PropertyValue.null_value()
    assert_true(null_val.is_null())

    let bool_val = PropertyValue.boolean(True)
    assert_true(not bool_val.is_null())
    assert_true(bool_val.bool_val)

    let int_val = PropertyValue.integer(42)
    assert_equal(int_val.int_val, 42)

    let float_val = PropertyValue.double(3.14)
    assert_true(float_val.float_val > 3.0)

    let str_val = PropertyValue.from_string("hello")
    assert_equal(str_val.string_val, "hello")
    print("✓ PropertyValue type tests passed")


fn test_node_label():
    """Test NodeLabel creation and properties."""
    from graph import NodeLabel, PropertyDef
    from common import LogicalType

    var label = NodeLabel("Person", 1)
    assert_equal(label.name, "Person")
    assert_equal(label.get_num_properties(), 0)

    label.add_property(PropertyDef("name", LogicalType.STRING))
    label.add_property(PropertyDef.primary("id", LogicalType.INT64))
    assert_equal(label.get_num_properties(), 2)
    print("✓ NodeLabel tests passed")


fn test_graph_entry_node():
    """Test GraphEntry node operations."""
    from graph import GraphEntry, PropertyValue
    from common import InternalID

    let id = InternalID(1, 100)
    var entry = GraphEntry.node(id, "Person")

    assert_true(entry.is_node())
    assert_true(not entry.is_edge())
    assert_equal(entry.label, "Person")

    entry.set_property("name", PropertyValue.from_string("Alice"))
    entry.set_property("age", PropertyValue.integer(30))

    let name = entry.get_property("name")
    assert_equal(name.string_val, "Alice")

    let age = entry.get_property("age")
    assert_equal(age.int_val, 30)

    let missing = entry.get_property("nonexistent")
    assert_true(missing.is_null())
    print("✓ GraphEntry node tests passed")


fn test_graph_entry_edge():
    """Test GraphEntry edge operations."""
    from graph import GraphEntry, PropertyValue
    from common import InternalID

    let id = InternalID(2, 0)
    var edge = GraphEntry.edge(id, "KNOWS")

    assert_true(edge.is_edge())
    assert_true(not edge.is_node())
    assert_equal(edge.label, "KNOWS")

    edge.set_property("since", PropertyValue.integer(2020))
    let since = edge.get_property("since")
    assert_equal(since.int_val, 2020)
    print("✓ GraphEntry edge tests passed")


fn test_path():
    """Test Path construction."""
    from graph import Path, GraphEntry
    from common import InternalID

    var path = Path()
    assert_equal(path.length(), 0)

    let n1 = GraphEntry.node(InternalID(1, 0), "Person")
    let n2 = GraphEntry.node(InternalID(1, 1), "Person")
    let n3 = GraphEntry.node(InternalID(1, 2), "Company")
    let e1 = GraphEntry.edge(InternalID(2, 0), "KNOWS")
    let e2 = GraphEntry.edge(InternalID(3, 0), "WORKS_FOR")

    path.add_node(n1)
    path.add_edge(e1)
    path.add_node(n2)
    path.add_edge(e2)
    path.add_node(n3)

    assert_equal(path.length(), 2)

    let start = path.get_start_node()
    assert_equal(start.label, "Person")

    let end = path.get_end_node()
    assert_equal(end.label, "Company")
    print("✓ Path tests passed")


fn test_graph_schema():
    """Test GraphSchema with node labels and rel types."""
    from graph import Graph

    var graph = Graph("test_graph")

    graph.create_node_label("Person")
    graph.create_node_label("Company")
    graph.create_node_label("City")
    graph.create_rel_type("WORKS_FOR", "Person", "Company")
    graph.create_rel_type("LIVES_IN", "Person", "City")

    assert_true(graph.has_node_label("Person"))
    assert_true(graph.has_node_label("Company"))
    assert_true(graph.has_node_label("City"))
    assert_true(not graph.has_node_label("Unknown"))

    assert_true(graph.has_rel_type("WORKS_FOR"))
    assert_true(graph.has_rel_type("LIVES_IN"))
    assert_true(not graph.has_rel_type("UNKNOWN"))

    assert_equal(graph.get_num_node_labels(), 3)
    assert_equal(graph.get_num_rel_types(), 2)
    print("✓ GraphSchema tests passed")


fn test_patterns():
    """Test node and edge pattern matching."""
    from graph import NodePattern, EdgePattern, Direction, PropertyValue

    var np = NodePattern()
    np.set_variable("n")
    np.add_label("Person")
    np.add_property("age", PropertyValue.integer(25))
    assert_equal(len(np.labels), 1)
    assert_equal(np.variable, "n")

    var ep = EdgePattern(Direction.FORWARD)
    ep.set_variable("r")
    ep.add_type("KNOWS")
    assert_true(not ep.is_variable_length())

    ep.set_length_range(1, 5)
    assert_true(ep.is_variable_length())

    var both = EdgePattern(Direction.BOTH)
    assert_true(not both.is_variable_length())
    print("✓ Pattern tests passed")


fn main():
    """Run all graph tests."""
    print("Running graph module tests...")
    test_property_value_types()
    test_node_label()
    test_graph_entry_node()
    test_graph_entry_edge()
    test_path()
    test_graph_schema()
    test_patterns()
    print("All graph tests passed! ✓")

