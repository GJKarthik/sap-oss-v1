"""
GraphQL Schema Generator with Vocabulary Mapping

Phase 5.2: Generate GraphQL schemas from OData vocabulary definitions.
Maps OData types and annotations to GraphQL types and directives.
"""

from typing import Dict, List, Optional, Any, Set
import json


class GraphQLSchemaGenerator:
    """
    Generates GraphQL schemas from OData entity definitions with vocabulary mapping.
    
    Features:
    - OData to GraphQL type mapping
    - Custom directives for OData annotations
    - Query/Mutation generation
    - Subscription support for real-time
    - Connection-based pagination (Relay style)
    """
    
    # OData to GraphQL type mapping
    TYPE_MAP = {
        # Primitives
        "Edm.String": "String",
        "Edm.Int32": "Int",
        "Edm.Int64": "Int",
        "Edm.Int16": "Int",
        "Edm.Byte": "Int",
        "Edm.SByte": "Int",
        "Edm.Decimal": "Float",
        "Edm.Double": "Float",
        "Edm.Single": "Float",
        "Edm.Boolean": "Boolean",
        "Edm.Guid": "ID",
        "Edm.DateTimeOffset": "DateTime",
        "Edm.Date": "Date",
        "Edm.TimeOfDay": "Time",
        "Edm.Duration": "String",
        "Edm.Binary": "String",
        "Edm.Stream": "String",
        # CDS types
        "cds.String": "String",
        "cds.Integer": "Int",
        "cds.Decimal": "Float",
        "cds.Boolean": "Boolean",
        "cds.Date": "Date",
        "cds.Timestamp": "DateTime",
        "cds.UUID": "ID",
    }
    
    def __init__(self, vocabularies: Dict = None):
        """
        Initialize generator with vocabulary definitions.
        
        Args:
            vocabularies: Dict of vocabulary definitions from MCP server
        """
        self.vocabularies = vocabularies or {}
    
    def generate_schema(self,
                       entities: List[Dict],
                       options: Dict = None) -> str:
        """
        Generate complete GraphQL schema from entity definitions.
        
        Args:
            entities: List of entity definitions
            options: Generation options
            
        Returns:
            Complete GraphQL schema string
        """
        options = options or {}
        include_directives = options.get("include_directives", True)
        include_subscriptions = options.get("include_subscriptions", True)
        relay_style = options.get("relay_style", True)
        
        lines = []
        
        # Schema header
        lines.append("# GraphQL Schema Generated from OData Vocabularies")
        lines.append("# Generated with vocabulary-based type mapping")
        lines.append("")
        
        # Custom scalar types
        lines.extend(self._generate_scalars())
        lines.append("")
        
        # Custom directives for OData annotations
        if include_directives:
            lines.extend(self._generate_directives())
            lines.append("")
        
        # Interface for entities with IDs
        if relay_style:
            lines.extend(self._generate_node_interface())
            lines.append("")
        
        # Generate types for each entity
        type_names = set()
        for entity in entities:
            entity_type = self._generate_entity_type(entity, options)
            lines.append(entity_type)
            lines.append("")
            type_names.add(entity["name"])
            
            # Generate input type for mutations
            input_type = self._generate_input_type(entity)
            lines.append(input_type)
            lines.append("")
            
            # Generate connection type for pagination
            if relay_style:
                connection_type = self._generate_connection_type(entity["name"])
                lines.append(connection_type)
                lines.append("")
        
        # Generate Query type
        lines.extend(self._generate_query_type(entities, relay_style))
        lines.append("")
        
        # Generate Mutation type
        lines.extend(self._generate_mutation_type(entities))
        lines.append("")
        
        # Generate Subscription type
        if include_subscriptions:
            lines.extend(self._generate_subscription_type(entities))
            lines.append("")
        
        return "\n".join(lines)
    
    def _generate_scalars(self) -> List[str]:
        """Generate custom scalar type definitions"""
        return [
            "# Custom Scalar Types",
            'scalar DateTime @specifiedBy(url: "https://scalars.graphql.org/andimarek/date-time")',
            'scalar Date @specifiedBy(url: "https://scalars.graphql.org/andimarek/local-date")',
            'scalar Time @specifiedBy(url: "https://scalars.graphql.org/andimarek/local-time")',
            'scalar Decimal @specifiedBy(url: "https://ibm.github.io/graphql-specs/custom-scalars/decimal.html")',
            'scalar JSON @specifiedBy(url: "https://www.ecma-international.org/publications/standards/Ecma-404.htm")',
        ]
    
    def _generate_directives(self) -> List[str]:
        """Generate custom directives for OData vocabulary annotations"""
        return [
            "# OData Vocabulary Directives",
            "",
            '"""',
            "Common.Label - Human-readable label for the field",
            '"""',
            "directive @label(value: String!) on FIELD_DEFINITION",
            "",
            '"""',
            "Analytics.Dimension - Marks field as analytical dimension",
            '"""',
            "directive @dimension on FIELD_DEFINITION",
            "",
            '"""',
            "Analytics.Measure - Marks field as analytical measure",
            '"""',
            "directive @measure on FIELD_DEFINITION",
            "",
            '"""',
            "PersonalData.IsPotentiallyPersonal - GDPR personal data marker",
            '"""',
            "directive @personalData on FIELD_DEFINITION",
            "",
            '"""',
            "PersonalData.IsPotentiallySensitive - GDPR sensitive data marker",
            '"""',
            "directive @sensitiveData on FIELD_DEFINITION",
            "",
            '"""',
            "UI.Hidden - Field should not be displayed",
            '"""',
            "directive @hidden on FIELD_DEFINITION",
            "",
            '"""',
            "Common.SemanticKey - Part of the semantic key",
            '"""',
            "directive @semanticKey on FIELD_DEFINITION",
            "",
            '"""',
            "Measures.ISOCurrency - Currency code reference",
            '"""',
            "directive @currency(path: String!) on FIELD_DEFINITION",
            "",
            '"""',
            "Measures.Unit - Unit of measure reference",
            '"""',
            "directive @unit(path: String!) on FIELD_DEFINITION",
        ]
    
    def _generate_node_interface(self) -> List[str]:
        """Generate Relay-style Node interface"""
        return [
            "# Relay Node Interface",
            '"""',
            "An object with a global ID",
            '"""',
            "interface Node {",
            "    id: ID!",
            "}",
            "",
            "# Page Info for Connections",
            "type PageInfo {",
            "    hasNextPage: Boolean!",
            "    hasPreviousPage: Boolean!",
            "    startCursor: String",
            "    endCursor: String",
            "}",
        ]
    
    def _generate_entity_type(self, entity: Dict, options: Dict) -> str:
        """Generate GraphQL type for an entity"""
        name = entity.get("name", "")
        properties = entity.get("properties", [])
        description = entity.get("description", f"Entity type: {name}")
        implements_node = options.get("relay_style", True)
        
        lines = []
        lines.append(f'"""')
        lines.append(f'{description}')
        lines.append(f'"""')
        
        implements = " implements Node" if implements_node else ""
        lines.append(f"type {name}{implements} {{")
        
        # Add id field if not present
        has_id = any(p.get("name") == "id" for p in properties)
        if implements_node and not has_id:
            lines.append("    id: ID!")
        
        # Generate fields
        for prop in properties:
            field_def = self._generate_field(prop)
            lines.append(f"    {field_def}")
        
        lines.append("}")
        return "\n".join(lines)
    
    def _generate_field(self, prop: Dict) -> str:
        """Generate a GraphQL field definition"""
        name = prop.get("name", "")
        odata_type = prop.get("type", "Edm.String")
        nullable = prop.get("nullable", True)
        description = prop.get("description", "")
        semantics = prop.get("semantics", {})
        
        # Map OData type to GraphQL
        graphql_type = self._map_type(odata_type)
        
        # Handle collections
        is_collection = "Collection(" in odata_type
        if is_collection:
            inner_type = odata_type.replace("Collection(", "").rstrip(")")
            graphql_type = f"[{self._map_type(inner_type)}]"
        
        # Add non-null marker if required
        if not nullable and prop.get("key"):
            graphql_type = f"{graphql_type}!"
        elif prop.get("key"):
            graphql_type = f"{graphql_type}!"
        
        # Build directives
        directives = []
        
        # Label directive
        label = semantics.get("label") or self._generate_label(name)
        directives.append(f'@label(value: "{label}")')
        
        # Analytics directives
        if self._is_dimension(name, odata_type, semantics):
            directives.append("@dimension")
        elif self._is_measure(name, odata_type, semantics):
            directives.append("@measure")
        
        # PersonalData directives
        if self._is_personal_data(name, semantics):
            directives.append("@personalData")
        if self._is_sensitive_data(name, semantics):
            directives.append("@sensitiveData")
        
        # Currency/Unit directives
        currency_path = semantics.get("currency_path")
        if currency_path:
            directives.append(f'@currency(path: "{currency_path}")')
        
        unit_path = semantics.get("unit_path")
        if unit_path:
            directives.append(f'@unit(path: "{unit_path}")')
        
        directive_str = " " + " ".join(directives) if directives else ""
        return f"{name}: {graphql_type}{directive_str}"
    
    def _generate_input_type(self, entity: Dict) -> str:
        """Generate GraphQL input type for mutations"""
        name = entity.get("name", "")
        properties = entity.get("properties", [])
        
        lines = []
        lines.append(f'"""')
        lines.append(f'Input type for creating/updating {name}')
        lines.append(f'"""')
        lines.append(f"input {name}Input {{")
        
        for prop in properties:
            prop_name = prop.get("name", "")
            odata_type = prop.get("type", "Edm.String")
            nullable = prop.get("nullable", True)
            
            graphql_type = self._map_type(odata_type)
            
            # Input types are nullable by default (for partial updates)
            lines.append(f"    {prop_name}: {graphql_type}")
        
        lines.append("}")
        return "\n".join(lines)
    
    def _generate_connection_type(self, entity_name: str) -> str:
        """Generate Relay-style connection type"""
        lines = []
        
        # Connection type
        lines.append(f"type {entity_name}Connection {{")
        lines.append(f"    edges: [{entity_name}Edge]")
        lines.append("    pageInfo: PageInfo!")
        lines.append("    totalCount: Int")
        lines.append("}")
        lines.append("")
        
        # Edge type
        lines.append(f"type {entity_name}Edge {{")
        lines.append(f"    node: {entity_name}")
        lines.append("    cursor: String!")
        lines.append("}")
        
        return "\n".join(lines)
    
    def _generate_query_type(self, entities: List[Dict], relay_style: bool) -> List[str]:
        """Generate Query type"""
        lines = []
        lines.append("type Query {")
        lines.append('    """')
        lines.append("    Fetch a node by global ID")
        lines.append('    """')
        lines.append("    node(id: ID!): Node")
        lines.append("")
        
        for entity in entities:
            name = entity.get("name", "")
            name_lower = self._to_camel_case(name)
            
            # Single entity query
            lines.append(f'    """')
            lines.append(f'    Fetch a single {name} by ID')
            lines.append(f'    """')
            lines.append(f"    {name_lower}(id: ID!): {name}")
            lines.append("")
            
            # Collection query
            if relay_style:
                lines.append(f'    """')
                lines.append(f'    Fetch {name} entities with pagination')
                lines.append(f'    """')
                lines.append(f"    {name_lower}s(")
                lines.append("        first: Int")
                lines.append("        after: String")
                lines.append("        last: Int")
                lines.append("        before: String")
                lines.append("        filter: String")
                lines.append("        orderBy: String")
                lines.append(f"    ): {name}Connection")
            else:
                lines.append(f'    """')
                lines.append(f'    Fetch all {name} entities')
                lines.append(f'    """')
                lines.append(f"    {name_lower}s(skip: Int, top: Int, filter: String): [{name}]")
            lines.append("")
        
        lines.append("}")
        return lines
    
    def _generate_mutation_type(self, entities: List[Dict]) -> List[str]:
        """Generate Mutation type"""
        lines = []
        lines.append("type Mutation {")
        
        for entity in entities:
            name = entity.get("name", "")
            name_lower = self._to_camel_case(name)
            
            # Create mutation
            lines.append(f'    """')
            lines.append(f'    Create a new {name}')
            lines.append(f'    """')
            lines.append(f"    create{name}(input: {name}Input!): {name}")
            lines.append("")
            
            # Update mutation
            lines.append(f'    """')
            lines.append(f'    Update an existing {name}')
            lines.append(f'    """')
            lines.append(f"    update{name}(id: ID!, input: {name}Input!): {name}")
            lines.append("")
            
            # Delete mutation
            lines.append(f'    """')
            lines.append(f'    Delete a {name}')
            lines.append(f'    """')
            lines.append(f"    delete{name}(id: ID!): Boolean")
            lines.append("")
        
        lines.append("}")
        return lines
    
    def _generate_subscription_type(self, entities: List[Dict]) -> List[str]:
        """Generate Subscription type"""
        lines = []
        lines.append("type Subscription {")
        
        for entity in entities:
            name = entity.get("name", "")
            name_lower = self._to_camel_case(name)
            
            # Change subscription
            lines.append(f'    """')
            lines.append(f'    Subscribe to {name} changes')
            lines.append(f'    """')
            lines.append(f"    {name_lower}Changed(id: ID): {name}")
            lines.append("")
        
        lines.append("}")
        return lines
    
    # Helper methods
    def _map_type(self, odata_type: str) -> str:
        """Map OData type to GraphQL type"""
        # Check direct mapping
        if odata_type in self.TYPE_MAP:
            return self.TYPE_MAP[odata_type]
        
        # Handle complex types as references
        if "." in odata_type:
            # Extract type name
            parts = odata_type.split(".")
            return parts[-1]
        
        return "String"  # Default fallback
    
    def _generate_label(self, name: str) -> str:
        """Generate human-readable label"""
        import re
        result = re.sub(r'([A-Z])', r' \1', name).strip()
        result = result.replace('_', ' ')
        return ' '.join(word.capitalize() for word in result.split())
    
    def _to_camel_case(self, name: str) -> str:
        """Convert PascalCase to camelCase"""
        if not name:
            return name
        return name[0].lower() + name[1:]
    
    def _is_dimension(self, name: str, type_: str, semantics: Dict) -> bool:
        """Check if field is an analytics dimension"""
        if semantics.get("dimension"):
            return True
        return any(kw in name.lower() for kw in ["id", "code", "key", "type", "category"])
    
    def _is_measure(self, name: str, type_: str, semantics: Dict) -> bool:
        """Check if field is an analytics measure"""
        if semantics.get("measure"):
            return True
        if type_ in ["Edm.Decimal", "Edm.Double", "Edm.Int32", "Edm.Int64"]:
            return any(kw in name.lower() for kw in ["amount", "quantity", "value", "price", "count"])
        return False
    
    def _is_personal_data(self, name: str, semantics: Dict) -> bool:
        """Check if field contains personal data"""
        if semantics.get("personal"):
            return True
        return any(kw in name.lower() for kw in ["name", "email", "phone", "address"])
    
    def _is_sensitive_data(self, name: str, semantics: Dict) -> bool:
        """Check if field contains sensitive data"""
        if semantics.get("sensitive"):
            return True
        return any(kw in name.lower() for kw in ["health", "medical", "ethnic", "religion"])
    
    def generate_resolver_stubs(self, entities: List[Dict]) -> str:
        """
        Generate resolver stub code (JavaScript/TypeScript style).
        
        Args:
            entities: List of entity definitions
            
        Returns:
            Resolver stub code
        """
        lines = []
        lines.append("// GraphQL Resolvers generated from OData Vocabularies")
        lines.append("")
        lines.append("const resolvers = {")
        
        # Query resolvers
        lines.append("    Query: {")
        lines.append("        node: (_, { id }) => {")
        lines.append("            // Implement node lookup by global ID")
        lines.append("            return null;")
        lines.append("        },")
        
        for entity in entities:
            name = entity.get("name", "")
            name_lower = self._to_camel_case(name)
            lines.append(f"        {name_lower}: (_, {{ id }}) => {{")
            lines.append(f"            // Fetch {name} by ID from OData service")
            lines.append(f"            return null;")
            lines.append(f"        }},")
            lines.append(f"        {name_lower}s: (_, {{ first, after, filter }}) => {{")
            lines.append(f"            // Fetch {name} collection with OData query")
            lines.append(f"            return {{ edges: [], pageInfo: {{ hasNextPage: false, hasPreviousPage: false }} }};")
            lines.append(f"        }},")
        
        lines.append("    },")
        
        # Mutation resolvers
        lines.append("    Mutation: {")
        for entity in entities:
            name = entity.get("name", "")
            lines.append(f"        create{name}: (_, {{ input }}) => {{")
            lines.append(f"            // Create {name} via OData POST")
            lines.append(f"            return null;")
            lines.append(f"        }},")
            lines.append(f"        update{name}: (_, {{ id, input }}) => {{")
            lines.append(f"            // Update {name} via OData PATCH")
            lines.append(f"            return null;")
            lines.append(f"        }},")
            lines.append(f"        delete{name}: (_, {{ id }}) => {{")
            lines.append(f"            // Delete {name} via OData DELETE")
            lines.append(f"            return true;")
            lines.append(f"        }},")
        
        lines.append("    },")
        lines.append("};")
        lines.append("")
        lines.append("module.exports = resolvers;")
        
        return "\n".join(lines)


# Singleton instance
_generator_instance: Optional[GraphQLSchemaGenerator] = None


def get_graphql_generator(vocabularies: Dict = None) -> GraphQLSchemaGenerator:
    """Get or create the GraphQLSchemaGenerator singleton"""
    global _generator_instance
    if _generator_instance is None:
        _generator_instance = GraphQLSchemaGenerator(vocabularies)
    return _generator_instance