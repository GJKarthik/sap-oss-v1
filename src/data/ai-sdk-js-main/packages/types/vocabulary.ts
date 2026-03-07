/**
 * OData Vocabulary Types - Auto-generated from SAP OData vocabulary definitions
 * 
 * This module provides TypeScript types for OData vocabulary annotations,
 * enabling type-safe annotation handling in the SAP AI SDK.
 * 
 * @module @sap-ai-sdk/types/vocabulary
 */

// =============================================================================
// UI Vocabulary Types (com.sap.vocabularies.UI.v1)
// =============================================================================

/**
 * UI.LineItem - Collection of data fields for table display
 */
export interface UILineItem {
  /** The property path or expression to display */
  Value: string;
  /** Human-readable label */
  Label?: string;
  /** Importance level for responsive display */
  Importance?: UIImportance;
  /** Criticality indicator */
  Criticality?: string;
  /** Navigation target */
  SemanticObject?: string;
  /** Action binding */
  Action?: string;
}

/**
 * UI.HeaderInfo - Header information for object pages
 */
export interface UIHeaderInfo {
  /** Type name (singular) */
  TypeName: string;
  /** Type name (plural) */
  TypeNamePlural: string;
  /** Title configuration */
  Title: UIDataField;
  /** Description configuration */
  Description?: UIDataField;
  /** Image URL or path */
  ImageUrl?: string;
  /** Icon URL */
  IconUrl?: string;
}

/**
 * UI.DataField - Generic data field for displaying property values
 */
export interface UIDataField {
  /** Property path or value */
  Value: string;
  /** Optional label override */
  Label?: string;
  /** Criticality for visual indicators */
  Criticality?: string;
  /** Whether to hide the field */
  Hidden?: boolean;
}

/**
 * UI.SelectionFields - Properties for filter bar
 */
export interface UISelectionFields {
  /** Array of property paths */
  PropertyPath: string[];
}

/**
 * UI.FieldGroup - Group of fields for form layout
 */
export interface UIFieldGroup {
  /** Group label */
  Label?: string;
  /** Data fields in the group */
  Data: UIDataField[];
}

/**
 * UI.Facets - Facets for object page sections
 */
export interface UIFacet {
  /** Facet type */
  $Type: 'UI.ReferenceFacet' | 'UI.CollectionFacet';
  /** Label for the facet */
  Label?: string;
  /** Target for reference facets */
  Target?: string;
  /** Child facets for collection facets */
  Facets?: UIFacet[];
  /** Unique identifier */
  ID?: string;
}

/**
 * UI.Chart - Chart visualization configuration
 */
export interface UIChart {
  /** Chart type */
  ChartType: UIChartType;
  /** Title */
  Title?: string;
  /** Measures (numeric values) */
  Measures: string[];
  /** Dimensions (grouping) */
  Dimensions: string[];
  /** Measure attributes */
  MeasureAttributes?: UIMeasureAttribute[];
  /** Dimension attributes */
  DimensionAttributes?: UIDimensionAttribute[];
}

/**
 * UI.PresentationVariant - Display variant configuration
 */
export interface UIPresentationVariant {
  /** Text description */
  Text?: string;
  /** Sort order */
  SortOrder?: UISortOrder[];
  /** Visualizations */
  Visualizations?: string[];
  /** Maximum items to display */
  MaxItems?: number;
}

// UI Enumerations
export type UIImportance = 'High' | 'Medium' | 'Low';
export type UIChartType = 'Column' | 'Bar' | 'Line' | 'Pie' | 'Donut' | 'Area' | 'Scatter' | 'Bubble' | 'HeatMap' | 'TreeMap' | 'Waterfall';

export interface UISortOrder {
  Property: string;
  Descending?: boolean;
}

export interface UIMeasureAttribute {
  Measure: string;
  Role?: 'Axis1' | 'Axis2' | 'Axis3';
}

export interface UIDimensionAttribute {
  Dimension: string;
  Role?: 'Category' | 'Series';
}

// =============================================================================
// Analytics Vocabulary Types (com.sap.vocabularies.Analytics.v1)
// =============================================================================

/**
 * Analytics.Measure - Indicates the property is a measure/KPI
 */
export interface AnalyticsMeasure {
  /** True if this is a measure */
  value: boolean;
  /** Aggregation method */
  aggregationType?: AggregationType;
}

/**
 * Analytics.Dimension - Indicates the property is a dimension
 */
export interface AnalyticsDimension {
  /** True if this is a dimension */
  value: boolean;
  /** Optional hierarchy */
  hierarchy?: string;
}

/**
 * Analytics.AccumulativeMeasure - Accumulative measure (YTD, QTD, etc.)
 */
export interface AnalyticsAccumulativeMeasure {
  value: boolean;
  periodType?: 'Year' | 'Quarter' | 'Month' | 'Week' | 'Day';
}

export type AggregationType = 'sum' | 'avg' | 'count' | 'min' | 'max' | 'countdistinct';

// =============================================================================
// Common Vocabulary Types (com.sap.vocabularies.Common.v1)
// =============================================================================

/**
 * Common.Label - Human-readable label
 */
export interface CommonLabel {
  /** Label text */
  value: string;
  /** Language code (optional) */
  language?: string;
}

/**
 * Common.SemanticKey - Properties that identify an entity instance
 */
export interface CommonSemanticKey {
  /** Array of property paths */
  PropertyPath: string[];
}

/**
 * Common.Text - Text for a property (display value)
 */
export interface CommonText {
  /** Property path for the text */
  value: string;
  /** Text arrangement */
  TextArrangement?: CommonTextArrangement;
}

/**
 * Common.ValueList - Value help configuration
 */
export interface CommonValueList {
  /** Collection path for value list */
  CollectionPath: string;
  /** Label for the value list */
  Label?: string;
  /** Parameters for the value list */
  Parameters: CommonValueListParameter[];
  /** Search supported */
  SearchSupported?: boolean;
}

export interface CommonValueListParameter {
  /** Local property */
  LocalDataProperty: string;
  /** Value list property */
  ValueListProperty: string;
}

export type CommonTextArrangement = 'TextFirst' | 'TextLast' | 'TextOnly' | 'TextSeparate';

// =============================================================================
// PersonalData Vocabulary Types (com.sap.vocabularies.PersonalData.v1)
// =============================================================================

/**
 * PersonalData - GDPR personal data annotations
 */
export interface PersonalDataAnnotation {
  /** Potentially personal data */
  IsPotentiallyPersonal?: boolean;
  /** Potentially sensitive data */
  IsPotentiallySensitive?: boolean;
  /** Data subject role */
  DataSubjectRole?: DataSubjectRole;
  /** Field semantics */
  FieldSemantics?: FieldSemantics;
}

export type DataSubjectRole = 'DataSubject' | 'DataController' | 'DataProcessor';

export type FieldSemantics = 
  | 'givenName' 
  | 'familyName' 
  | 'email' 
  | 'phone' 
  | 'address' 
  | 'birthDate' 
  | 'gender'
  | 'nationality'
  | 'photo'
  | 'socialSecurityNumber'
  | 'taxId'
  | 'creditCard'
  | 'bankAccount';

// =============================================================================
// Aggregation Vocabulary Types (Org.OData.Aggregation.V1)
// =============================================================================

/**
 * Aggregation.Groupable - Property can be used for grouping
 */
export interface AggregationGroupable {
  value: boolean;
}

/**
 * Aggregation.Aggregatable - Property can be aggregated
 */
export interface AggregationAggregatable {
  value: boolean;
}

// =============================================================================
// Annotation Helper Types
// =============================================================================

/**
 * Target types for annotations
 */
export type AnnotationTarget = 
  | 'EntityType' 
  | 'EntitySet' 
  | 'Property' 
  | 'NavigationProperty' 
  | 'Action' 
  | 'Function'
  | 'Parameter';

/**
 * Annotation suggestion from vocabulary service
 */
export interface AnnotationSuggestion {
  /** Qualified term name */
  term: string;
  /** Vocabulary name */
  vocabulary: string;
  /** Applicable targets */
  applicability: AnnotationTarget[];
  /** Example usage */
  example: string;
  /** Description */
  description: string;
}

/**
 * Vocabulary term metadata
 */
export interface VocabularyTerm {
  /** Term name */
  name: string;
  /** Full qualified name */
  qualifiedName: string;
  /** Vocabulary */
  vocabulary: string;
  /** Namespace */
  namespace: string;
  /** Type */
  type: string;
  /** Description */
  description: string;
  /** Applicable to */
  appliesTo: AnnotationTarget[];
  /** Base type (if any) */
  baseType?: string;
  /** Is deprecated */
  deprecated?: boolean;
}

// =============================================================================
// Vocabulary Service Client Types
// =============================================================================

/**
 * Request to search vocabulary terms
 */
export interface VocabularySearchRequest {
  /** Search query */
  query: string;
  /** Filter by vocabulary */
  vocabulary?: string;
  /** Maximum results */
  limit?: number;
  /** Include deprecated terms */
  includeDeprecated?: boolean;
}

/**
 * Response from vocabulary search
 */
export interface VocabularySearchResponse {
  /** Search results */
  results: VocabularyTerm[];
  /** Total count */
  totalCount: number;
  /** Query executed */
  query: string;
}

/**
 * Request to suggest annotations
 */
export interface AnnotationSuggestionRequest {
  /** Entity type name */
  entityType: string;
  /** Properties to annotate */
  properties: PropertyDefinition[];
  /** Target vocabularies */
  vocabularies?: string[];
  /** Use case context */
  useCase?: 'fiori' | 'cap' | 'odata';
}

/**
 * Property definition for annotation suggestions
 */
export interface PropertyDefinition {
  /** Property name */
  name: string;
  /** Property type */
  type: string;
  /** Is key property */
  isKey?: boolean;
  /** Is nullable */
  nullable?: boolean;
  /** Max length for strings */
  maxLength?: number;
}

/**
 * Response from annotation suggestions
 */
export interface AnnotationSuggestionResponse {
  /** Entity type */
  entityType: string;
  /** Suggested annotations by property */
  annotations: Record<string, AnnotationSuggestion[]>;
  /** Entity-level annotations */
  entityAnnotations: AnnotationSuggestion[];
}

// =============================================================================
// Exports
// =============================================================================

export const VOCABULARY_NAMESPACES = {
  UI: 'com.sap.vocabularies.UI.v1',
  Common: 'com.sap.vocabularies.Common.v1',
  Analytics: 'com.sap.vocabularies.Analytics.v1',
  PersonalData: 'com.sap.vocabularies.PersonalData.v1',
  Communication: 'com.sap.vocabularies.Communication.v1',
  Aggregation: 'Org.OData.Aggregation.V1',
  Core: 'Org.OData.Core.V1',
  Capabilities: 'Org.OData.Capabilities.V1',
  Validation: 'Org.OData.Validation.V1',
} as const;

export type VocabularyNamespace = keyof typeof VOCABULARY_NAMESPACES;