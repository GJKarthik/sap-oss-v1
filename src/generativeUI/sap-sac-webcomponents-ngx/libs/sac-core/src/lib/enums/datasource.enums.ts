/**
 * DataSource Enums
 *
 * Re-exports shared enums from the package SDK bundle (single source of truth).
 * DimensionType, DimensionDataType, MeasureDataType, AggregationType, MemberType,
 * MemberStatus, VariableType, VariableInputType, LinkedAnalysisType, LinkedAnalysisScope
 * are NGX-only extras — kept below.
 */
export {
  FilterValueType,
  VariableValueType,
  MemberDisplayMode,
  MemberAccessMode,
  PauseMode,
  SortDirection,
  RankDirection,
  TimeRangeGranularity,
} from '@sap-oss/sac-sdk';

/** Dimension types (from mangle dimension_type facts) */
export enum DimensionType {
  Account = 'Account',
  Category = 'Category',
  Date = 'Date',
  Entity = 'Entity',
  Flow = 'Flow',
  Generic = 'Generic',
  Measure = 'Measure',
  Organization = 'Organization',
  Time = 'Time',
  Version = 'Version',
}

/** Dimension data types */
export enum DimensionDataType {
  String = 'String',
  Integer = 'Integer',
  Date = 'Date',
  Time = 'Time',
  DateTime = 'DateTime',
}

/** Measure data types (from mangle measure_data_type facts) */
export enum MeasureDataType {
  Amount = 'Amount',
  Quantity = 'Quantity',
  Price = 'Price',
  Percentage = 'Percentage',
  Integer = 'Integer',
  Number = 'Number',
}

/** Aggregation types (from mangle aggregation_type facts) */
export enum AggregationType {
  SUM = 'SUM',
  AVG = 'AVG',
  MIN = 'MIN',
  MAX = 'MAX',
  COUNT = 'COUNT',
  COUNTD = 'COUNTD',
  FIRST = 'FIRST',
  LAST = 'LAST',
  NOP = 'NOP',
}

/** Member types (from mangle member_type facts) */
export enum MemberType {
  Base = 'Base',
  Parent = 'Parent',
  Text = 'Text',
  Formula = 'Formula',
}

/** Member status (from mangle member_status facts) */
export enum MemberStatus {
  Active = 'Active',
  Inactive = 'Inactive',
  Hidden = 'Hidden',
  ReadOnly = 'ReadOnly',
}

/** Variable types */
export enum VariableType {
  SingleValue = 'SingleValue',
  MultipleValue = 'MultipleValue',
  RangeValue = 'RangeValue',
  IntervalValue = 'IntervalValue',
}

/** Variable input types */
export enum VariableInputType {
  Optional = 'Optional',
  Mandatory = 'Mandatory',
  MandatoryNotInitial = 'MandatoryNotInitial',
}

/** Linked analysis types (from mangle linked_analysis_type facts) */
export enum LinkedAnalysisType {
  Drill = 'drill',
  Filter = 'filter',
  Selection = 'selection',
}

/** Linked analysis scope */
export enum LinkedAnalysisScope {
  SameModel = 'Same Model',
  AllModels = 'All Models',
  SelectedWidgets = 'Selected Widgets',
}
