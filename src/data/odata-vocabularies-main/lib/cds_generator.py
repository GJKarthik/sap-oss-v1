"""
CAP CDS Annotation Generator

Phase 5.1: Generate CAP CDS annotations from OData vocabularies.
Creates CDS annotation files using vocabulary definitions.
"""

from typing import Dict, List, Optional, Any
import json


class CDSAnnotationGenerator:
    """
    Generates SAP CAP CDS annotations from OData vocabulary definitions.
    
    Supports:
    - UI annotations (@UI.LineItem, @UI.HeaderInfo, etc.)
    - Common annotations (@Common.Label, @Common.Text, etc.)
    - Analytics annotations (@Analytics.Dimension, @Analytics.Measure)
    - PersonalData annotations (@PersonalData.*)
    """
    
    def __init__(self, vocabularies: Dict = None):
        """
        Initialize generator with vocabulary definitions.
        
        Args:
            vocabularies: Dict of vocabulary definitions from MCP server
        """
        self.vocabularies = vocabularies or {}
        
        # CDS annotation namespace mappings
        self.namespace_aliases = {
            "com.sap.vocabularies.UI.v1": "UI",
            "com.sap.vocabularies.Common.v1": "Common",
            "com.sap.vocabularies.Analytics.v1": "Analytics",
            "com.sap.vocabularies.PersonalData.v1": "PersonalData",
            "com.sap.vocabularies.Communication.v1": "Communication",
            "com.sap.vocabularies.Hierarchy.v1": "Hierarchy",
            "Org.OData.Measures.V1": "Measures",
            "Org.OData.Core.V1": "Core",
        }
    
    def generate_entity_annotations(self,
                                   entity_name: str,
                                   properties: List[Dict],
                                   options: Dict = None) -> str:
        """
        Generate CDS annotations for an entity type.
        
        Args:
            entity_name: Name of the entity
            properties: List of property definitions with name, type, semantics
            options: Generation options (include_ui, include_analytics, etc.)
            
        Returns:
            CDS annotation string
        """
        options = options or {}
        include_ui = options.get("include_ui", True)
        include_analytics = options.get("include_analytics", True)
        include_personal_data = options.get("include_personal_data", True)
        include_common = options.get("include_common", True)
        
        lines = []
        lines.append(f"// CDS Annotations for {entity_name}")
        lines.append(f"// Generated from OData Vocabularies")
        lines.append("")
        lines.append(f"annotate {entity_name} with {{")
        
        # Generate property annotations
        for prop in properties:
            prop_name = prop.get("name", "")
            prop_type = prop.get("type", "")
            label = prop.get("label", self._generate_label(prop_name))
            semantics = prop.get("semantics", {})
            
            prop_annotations = []
            
            # Common.Label
            if include_common:
                prop_annotations.append(f"@Common.Label: '{label}'")
            
            # Analytics annotations
            if include_analytics:
                if self._is_dimension(prop_name, prop_type, semantics):
                    prop_annotations.append("@Analytics.Dimension: true")
                elif self._is_measure(prop_name, prop_type, semantics):
                    prop_annotations.append("@Analytics.Measure: true")
            
            # PersonalData annotations
            if include_personal_data:
                pd_ann = self._get_personal_data_annotation(prop_name, semantics)
                if pd_ann:
                    prop_annotations.extend(pd_ann)
            
            # Measures annotations
            if self._is_currency_field(prop_name):
                currency_path = semantics.get("currency_path")
                if currency_path:
                    prop_annotations.append(f"@Measures.ISOCurrency: {currency_path}")
            
            if self._is_unit_field(prop_name):
                unit_path = semantics.get("unit_path")
                if unit_path:
                    prop_annotations.append(f"@Measures.Unit: {unit_path}")
            
            if prop_annotations:
                ann_str = " ".join(prop_annotations)
                lines.append(f"    {prop_name} {ann_str};")
        
        lines.append("};")
        
        # UI annotations
        if include_ui:
            lines.append("")
            lines.extend(self._generate_ui_annotations(entity_name, properties, options))
        
        return "\n".join(lines)
    
    def _generate_ui_annotations(self, entity_name: str, properties: List[Dict], options: Dict) -> List[str]:
        """Generate UI vocabulary annotations"""
        lines = []
        
        # HeaderInfo
        title_prop = self._find_title_property(properties)
        desc_prop = self._find_description_property(properties)
        
        lines.append(f"annotate {entity_name} with @UI: {{")
        lines.append("    HeaderInfo: {")
        lines.append(f"        TypeName: '{entity_name}',")
        lines.append(f"        TypeNamePlural: '{entity_name}s',")
        if title_prop:
            lines.append(f"        Title: {{ Value: {title_prop} }},")
        if desc_prop:
            lines.append(f"        Description: {{ Value: {desc_prop} }}")
        lines.append("    },")
        
        # SelectionFields
        key_props = [p["name"] for p in properties if p.get("key") or p.get("is_key")]
        filter_props = [p["name"] for p in properties 
                       if self._is_filter_field(p["name"], p.get("type", ""))][:5]
        selection_fields = key_props[:2] + filter_props[:3]
        if selection_fields:
            lines.append(f"    SelectionFields: [{', '.join(selection_fields)}],")
        
        # LineItem
        lines.append("    LineItem: [")
        visible_props = properties[:8]  # Show first 8 properties
        for i, prop in enumerate(visible_props):
            comma = "," if i < len(visible_props) - 1 else ""
            importance = "High" if prop.get("key") or i < 3 else "Medium"
            lines.append(f"        {{ Value: {prop['name']}, ![@UI.Importance]: #Importance.{importance} }}{comma}")
        lines.append("    ]")
        lines.append("};")
        
        return lines
    
    def generate_service_annotations(self,
                                    service_name: str,
                                    entities: List[Dict]) -> str:
        """
        Generate CDS annotations for an entire service.
        
        Args:
            service_name: Name of the service
            entities: List of entity definitions
            
        Returns:
            Complete CDS annotation file content
        """
        lines = []
        lines.append(f"// CDS Service Annotations: {service_name}")
        lines.append("// Generated from OData Vocabularies")
        lines.append("")
        lines.append("using { sap.common } from '@sap/cds/common';")
        lines.append("")
        
        for entity in entities:
            entity_name = entity.get("name", "")
            properties = entity.get("properties", [])
            
            entity_cds = self.generate_entity_annotations(
                f"{service_name}.{entity_name}",
                properties,
                entity.get("options", {})
            )
            lines.append(entity_cds)
            lines.append("")
        
        return "\n".join(lines)
    
    def generate_fiori_elements_annotations(self,
                                           entity_name: str,
                                           properties: List[Dict],
                                           page_type: str = "list") -> str:
        """
        Generate Fiori Elements specific annotations.
        
        Args:
            entity_name: Entity name
            properties: Property definitions
            page_type: list, object, or worklist
            
        Returns:
            CDS annotations for Fiori Elements
        """
        lines = []
        
        if page_type == "list":
            lines.extend(self._generate_list_report_annotations(entity_name, properties))
        elif page_type == "object":
            lines.extend(self._generate_object_page_annotations(entity_name, properties))
        elif page_type == "worklist":
            lines.extend(self._generate_worklist_annotations(entity_name, properties))
        
        return "\n".join(lines)
    
    def _generate_list_report_annotations(self, entity_name: str, properties: List[Dict]) -> List[str]:
        """Generate List Report annotations"""
        lines = []
        lines.append(f"// List Report Annotations for {entity_name}")
        lines.append(f"annotate {entity_name} with @UI.PresentationVariant: {{")
        lines.append("    SortOrder: [")
        
        # Sort by key or date fields
        sort_props = [p for p in properties if p.get("key") or "date" in p["name"].lower()][:2]
        for i, prop in enumerate(sort_props):
            comma = "," if i < len(sort_props) - 1 else ""
            lines.append(f"        {{ Property: {prop['name']}, Descending: false }}{comma}")
        
        lines.append("    ],")
        lines.append("    Visualizations: [@UI.LineItem]")
        lines.append("};")
        
        # Chart annotations if measures exist
        measures = [p for p in properties if self._is_measure(p["name"], p.get("type", ""), {})]
        dimensions = [p for p in properties if self._is_dimension(p["name"], p.get("type", ""), {})]
        
        if measures and dimensions:
            lines.append("")
            lines.append(f"annotate {entity_name} with @UI.Chart: {{")
            lines.append("    ChartType: #Column,")
            lines.append(f"    Dimensions: [{', '.join(d['name'] for d in dimensions[:2])}],")
            lines.append(f"    Measures: [{', '.join(m['name'] for m in measures[:2])}]")
            lines.append("};")
        
        return lines
    
    def _generate_object_page_annotations(self, entity_name: str, properties: List[Dict]) -> List[str]:
        """Generate Object Page annotations"""
        lines = []
        lines.append(f"// Object Page Annotations for {entity_name}")
        
        # Group properties into facets
        general_props = [p for p in properties if not self._is_detail_field(p["name"])][:6]
        detail_props = [p for p in properties if self._is_detail_field(p["name"])]
        
        lines.append(f"annotate {entity_name} with @UI.Facets: [")
        lines.append("    {")
        lines.append("        $Type: 'UI.ReferenceFacet',")
        lines.append("        Label: 'General Information',")
        lines.append("        ID: 'GeneralFacet',")
        lines.append("        Target: '@UI.FieldGroup#General'")
        lines.append("    },")
        
        if detail_props:
            lines.append("    {")
            lines.append("        $Type: 'UI.ReferenceFacet',")
            lines.append("        Label: 'Details',")
            lines.append("        ID: 'DetailsFacet',")
            lines.append("        Target: '@UI.FieldGroup#Details'")
            lines.append("    }")
        
        lines.append("];")
        
        # Field Groups
        lines.append("")
        lines.append(f"annotate {entity_name} with @UI.FieldGroup#General: {{")
        lines.append("    Data: [")
        for i, prop in enumerate(general_props):
            comma = "," if i < len(general_props) - 1 else ""
            lines.append(f"        {{ Value: {prop['name']} }}{comma}")
        lines.append("    ]")
        lines.append("};")
        
        if detail_props:
            lines.append("")
            lines.append(f"annotate {entity_name} with @UI.FieldGroup#Details: {{")
            lines.append("    Data: [")
            for i, prop in enumerate(detail_props[:5]):
                comma = "," if i < len(detail_props[:5]) - 1 else ""
                lines.append(f"        {{ Value: {prop['name']} }}{comma}")
            lines.append("    ]")
            lines.append("};")
        
        return lines
    
    def _generate_worklist_annotations(self, entity_name: str, properties: List[Dict]) -> List[str]:
        """Generate Worklist annotations"""
        lines = []
        lines.append(f"// Worklist Annotations for {entity_name}")
        
        # Find status field
        status_prop = next((p for p in properties if "status" in p["name"].lower()), None)
        
        lines.append(f"annotate {entity_name} with @UI.SelectionVariant#WorklistFilter: {{")
        lines.append("    Text: 'Open Items',")
        if status_prop:
            lines.append("    SelectOptions: [")
            lines.append(f"        {{ PropertyName: {status_prop['name']}, Ranges: [{{ Option: #EQ, Low: 'OPEN' }}] }}")
            lines.append("    ]")
        lines.append("};")
        
        return lines
    
    # Helper methods
    def _generate_label(self, prop_name: str) -> str:
        """Generate a human-readable label from property name"""
        # Handle common naming patterns
        result = prop_name
        # CamelCase to spaces
        import re
        result = re.sub(r'([A-Z])', r' \1', result).strip()
        # Underscores to spaces
        result = result.replace('_', ' ')
        # Capitalize words
        result = ' '.join(word.capitalize() for word in result.split())
        return result
    
    def _is_dimension(self, name: str, type_: str, semantics: Dict) -> bool:
        """Check if property is an analytics dimension"""
        if semantics.get("dimension"):
            return True
        name_lower = name.lower()
        return any(kw in name_lower for kw in ["id", "code", "key", "type", "category", "status"])
    
    def _is_measure(self, name: str, type_: str, semantics: Dict) -> bool:
        """Check if property is an analytics measure"""
        if semantics.get("measure"):
            return True
        name_lower = name.lower()
        if type_ in ["Edm.Decimal", "Edm.Double", "Edm.Int32", "Edm.Int64", "Integer", "Decimal"]:
            return any(kw in name_lower for kw in ["amount", "quantity", "value", "price", "count", "sum", "total"])
        return False
    
    def _is_currency_field(self, name: str) -> bool:
        """Check if field is currency-related"""
        return any(kw in name.lower() for kw in ["amount", "price", "value", "cost"])
    
    def _is_unit_field(self, name: str) -> bool:
        """Check if field is unit-related"""
        return any(kw in name.lower() for kw in ["quantity", "weight", "distance", "volume"])
    
    def _is_filter_field(self, name: str, type_: str) -> bool:
        """Check if field should be a filter"""
        return self._is_dimension(name, type_, {}) or "date" in name.lower()
    
    def _is_detail_field(self, name: str) -> bool:
        """Check if field is a detail (not for main list)"""
        return any(kw in name.lower() for kw in ["description", "note", "comment", "remark", "detail"])
    
    def _find_title_property(self, properties: List[Dict]) -> Optional[str]:
        """Find best property for title"""
        for prop in properties:
            name_lower = prop["name"].lower()
            if any(kw in name_lower for kw in ["name", "title", "subject"]):
                return prop["name"]
        # Fall back to first string property
        for prop in properties:
            if prop.get("type") in ["Edm.String", "String", "cds.String"]:
                return prop["name"]
        return properties[0]["name"] if properties else None
    
    def _find_description_property(self, properties: List[Dict]) -> Optional[str]:
        """Find best property for description"""
        for prop in properties:
            name_lower = prop["name"].lower()
            if any(kw in name_lower for kw in ["description", "desc", "text"]):
                return prop["name"]
        return None
    
    def _get_personal_data_annotation(self, name: str, semantics: Dict) -> List[str]:
        """Get PersonalData annotations for a property"""
        annotations = []
        name_lower = name.lower()
        
        # Check for personal data patterns
        if any(kw in name_lower for kw in ["name", "email", "phone", "address"]):
            annotations.append("@PersonalData.IsPotentiallyPersonal: true")
        
        # Check for sensitive patterns
        if any(kw in name_lower for kw in ["health", "medical", "ethnic", "religion"]):
            annotations.append("@PersonalData.IsPotentiallySensitive: true")
        
        # Field semantics
        if "email" in name_lower:
            annotations.append("@PersonalData.FieldSemantics: #emailAddress")
        elif "phone" in name_lower:
            annotations.append("@PersonalData.FieldSemantics: #phoneNumber")
        elif "birth" in name_lower and "date" in name_lower:
            annotations.append("@PersonalData.FieldSemantics: #birthDate")
        
        return annotations


# Singleton instance
_generator_instance: Optional[CDSAnnotationGenerator] = None


def get_cds_generator(vocabularies: Dict = None) -> CDSAnnotationGenerator:
    """Get or create the CDSAnnotationGenerator singleton"""
    global _generator_instance
    if _generator_instance is None:
        _generator_instance = CDSAnnotationGenerator(vocabularies)
    return _generator_instance