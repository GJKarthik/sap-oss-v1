/**
 * Metadata Types
 *
 * Type definitions for SAC DataSource metadata.
 * Derived from mangle/sac_datasource.mg dimension_type, measure_data_type facts.
 */

export type DimensionType = 'account' | 'date' | 'generic' | 'measure' | 'version';
export type DimensionDataType = 'string' | 'number' | 'date' | 'boolean';
export type MeasureDataType = 'number' | 'integer' | 'decimal' | 'currency';
export type AggregationType = 'sum' | 'average' | 'count' | 'min' | 'max' | 'none';
export type MemberType = 'leaf' | 'node' | 'calculated' | 'formula';
export type MemberStatus = 'active' | 'inactive' | 'restricted';
export type VariableType = 'single' | 'multiple' | 'interval' | 'hierarchy';
export type VariableInputType = 'manual' | 'derived' | 'exit';

/** Dimension information (from mangle dimension_type facts) */
export interface DimensionInfo {
  id: string;
  name: string;
  description?: string;
  type: DimensionType;
  dataType: DimensionDataType;
  isKey: boolean;
  hierarchyId?: string;
  properties: DimensionPropertyInfo[];
}

/** Dimension property information */
export interface DimensionPropertyInfo {
  id: string;
  name: string;
  dataType: DimensionDataType;
  isNavigable?: boolean;
}

/** Measure information (from mangle measure_data_type facts) */
export interface MeasureInfo {
  id: string;
  name: string;
  description?: string;
  dataType: MeasureDataType;
  aggregationType: AggregationType;
  unit?: string;
  currency?: string;
  decimals?: number;
  formula?: string;
  isCalculated?: boolean;
}

/** Member information (from mangle member_type, member_status facts) */
export interface MemberInfo {
  id: string;
  text: string;
  description?: string;
  type: MemberType;
  status: MemberStatus;
  parentId?: string;
  level?: number;
  isLeaf?: boolean;
  attributes?: Record<string, unknown>;
}

/** Hierarchy information */
export interface HierarchyInfo {
  id: string;
  name: string;
  dimensionId: string;
  levelCount: number;
  isRecursive?: boolean;
  levels: HierarchyLevelInfo[];
}

/** Hierarchy level information */
export interface HierarchyLevelInfo {
  id: string;
  name: string;
  level: number;
  memberCount?: number;
}

/** Variable information (from mangle variable_type facts) */
export interface VariableInfo {
  id: string;
  name: string;
  description?: string;
  type: VariableType;
  inputType: VariableInputType;
  dimensionId?: string;
  defaultValue?: VariableValue;
  currentValue?: VariableValue;
  isMandatory: boolean;
  isReadOnly?: boolean;
}

/** Variable value */
export interface VariableValue {
  type: VariableType;
  single?: string;
  multiple?: string[];
  rangeLow?: string;
  rangeHigh?: string;
}