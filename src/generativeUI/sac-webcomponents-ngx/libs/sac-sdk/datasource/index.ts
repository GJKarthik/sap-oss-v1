/**
 * @sap-oss/sac-webcomponents-ngx/sdk — DataSource, ResultSet, Selection, metadata types
 *
 * Specs:
 *   datasource/datasource_client.odps.yaml — DataSource class
 *   datasource/dimensioninfo_client.odps.yaml — DimensionInfo + DimensionType enum
 *   datasource/measureinfo_client.odps.yaml — MeasureInfo + MeasureDataType/AggregationType
 *   datasource/memberinfo_client.odps.yaml — MemberInfo + MemberType enum
 *   datasource/resultset_client.odps.yaml — ResultSet class
 *   datasource/selection_client.odps.yaml — Selection class
 *   datasource/selectioncontext_client.odps.yaml — SelectionContext type
 *   datasource/variableinfo_client.odps.yaml — VariableInfo + VariableType enums
 *   datasource/filtervalue_client.odps.yaml — FilterValue type
 *   datasource/datacell_client.odps.yaml — DataCell type
 *   datasource/hierarchyinfo_client.odps.yaml — HierarchyInfo
 * Backend: nUniversalPrompt-zig/zig/sacwidgetserver/datasource/ (36 handlers)
 */

import type { SACRestAPIClient } from '../client';
import type { OperationResult } from '../types';
import {
  type FilterValueType, type MemberDisplayMode,
  type MemberAccessMode, type TimeRangeGranularity,
  SortDirection, RankDirection, PauseMode,
} from '../types';

// ---------------------------------------------------------------------------
// Enums from specs
// ---------------------------------------------------------------------------

export enum DimensionType {
  Account = 'Account',
  Category = 'Category',
  Date = 'Date',
  Generic = 'Generic',
  Organization = 'Organization',
  Measure = 'Measure',
  Version = 'Version',
  AuditTrail = 'AuditTrail',
}

export enum MeasureDataType {
  Number = 'Number',
  Integer = 'Integer',
  Currency = 'Currency',
  Percentage = 'Percentage',
  Quantity = 'Quantity',
}

export enum AggregationType {
  Sum = 'SUM',
  Average = 'AVG',
  Count = 'CNT',
  Min = 'MIN',
  Max = 'MAX',
  First = 'FST',
  Last = 'LST',
  None = 'NOP',
}

export enum MeasureType {
  Basic = 'Basic',
  Calculated = 'Calculated',
  Restricted = 'Restricted',
  Formula = 'Formula',
}

export enum MemberType {
  Leaf = 'Leaf',
  Node = 'Node',
  Root = 'Root',
  Calculated = 'Calculated',
  All = 'All',
}

export enum MemberStatus {
  Active = 'Active',
  Inactive = 'Inactive',
  Blocked = 'Blocked',
  Deleted = 'Deleted',
}

export enum VariableType {
  SingleValue = 'SINGLE_VALUE',
  MultipleValues = 'MULTIPLE_VALUES',
  Range = 'RANGE',
  Interval = 'INTERVAL',
}

export enum VariableInputType {
  Mandatory = 'MANDATORY',
  Optional = 'OPTIONAL',
  ReadyForInput = 'READY_FOR_INPUT',
}

export enum DimensionDataType {
  String = 'String',
  Integer = 'Integer',
  Date = 'Date',
  DateTime = 'DateTime',
  Numeric = 'Numeric',
}

// ---------------------------------------------------------------------------
// Metadata interfaces — spec-aligned
// ---------------------------------------------------------------------------

export interface DimensionAttribute {
  id: string;
  description: string;
  dataType: DimensionDataType;
  isKey: boolean;
}

export interface DimensionHierarchy {
  id: string;
  description: string;
  isDefault: boolean;
  levelCount: number;
}

export interface DimensionProperty {
  id: string;
  description: string;
  dataType: DimensionDataType;
  isDisplayProperty: boolean;
}

export interface DimensionInfo {
  id: string;
  description: string;
  dimensionType: DimensionType;
  isAccountDimension: boolean;
  isTimeDimension: boolean;
  attributes?: DimensionAttribute[];
  properties?: DimensionProperty[];
  hierarchies?: DimensionHierarchy[];
}

export interface DimensionPropertyInfo {
  id: string;
  description?: string;
  dataType?: string;
  displayable?: boolean;
  filterable?: boolean;
}

export interface MeasureFormat {
  decimalPlaces: number;
  useThousandsSeparator: boolean;
  prefix?: string;
  suffix?: string;
  scale?: number;
}

export interface MeasureUnit {
  id: string;
  description: string;
  symbol: string;
  dimensionId?: string;
}

export interface MeasureInfo {
  id: string;
  description: string;
  dataType: MeasureDataType;
  measureType: MeasureType;
  aggregationType?: AggregationType;
  format?: MeasureFormat;
  unit?: MeasureUnit;
  currency?: string;
  isCalculated?: boolean;
  isInputReady?: boolean;
  isReadOnly?: boolean;
}

export interface HierarchyPosition {
  level: number;
  parentId: string;
  hasChildren: boolean;
  childCount: number;
}

export interface MemberAttribute {
  attributeId: string;
  value: unknown;
  formattedValue?: string;
}

export interface MemberInfo {
  id: string;
  description: string;
  memberType: MemberType;
  status?: MemberStatus;
  isLeaf?: boolean;
  parentId?: string;
  level?: number;
  hasChildren?: boolean;
  attributes?: MemberAttribute[];
  properties?: Record<string, unknown>;
}

export interface HierarchyInfo {
  id: string;
  description: string;
  isDefault?: boolean;
  levelCount?: number;
}

export interface VariableValue {
  id: string;
  description?: string;
  externalId?: string;
}

export interface VariableRange {
  low: unknown;
  high?: unknown;
  operator: string;
}

export interface VariableInfo {
  name: string;
  description: string;
  variableType: VariableType;
  inputType: VariableInputType;
  dataType?: string;
  dimensionName?: string;
  isMandatory?: boolean;
  isReadyForInput?: boolean;
  hasValue?: boolean;
  values?: VariableValue[];
  defaultValues?: VariableValue[];
}

export interface ModelInfo {
  id: string;
  description?: string;
}

// ---------------------------------------------------------------------------
// Data interfaces
// ---------------------------------------------------------------------------

export interface DataCell {
  formattedValue: string;
  rawValue: string;
}

export interface DataPoint {
  measure?: string;
  dimensions?: Record<string, string>;
  value?: number;
  formattedValue?: string;
}

export interface SelectionContext {
  [dimensionId: string]: string | string[];
}

// ---------------------------------------------------------------------------
// ResultSet types
// ---------------------------------------------------------------------------

export interface CellInfo {
  rowIndex: number;
  columnIndex: number;
  value: unknown;
  formattedValue: string;
  isTotal: boolean;
  isSubTotal: boolean;
}

export interface RowInfo {
  index: number;
  cells: CellInfo[];
  memberId?: string;
}

export interface ColumnInfo {
  index: number;
  dimensionId?: string;
  measureId?: string;
  header: string;
}

export interface ResultSetMetadata {
  rowCount: number;
  columnCount: number;
  hasMoreRows: boolean;
  dimensions: string[];
}

// ---------------------------------------------------------------------------
// Selection types
// ---------------------------------------------------------------------------

export interface SelectionMember {
  id: string;
  description: string;
  dimensionId: string;
  level: number;
  isLeaf: boolean;
}

export interface SelectionRange {
  fromMember: string;
  toMember: string;
  dimensionId: string;
  includeFrom: boolean;
  includeTo: boolean;
}

export interface SelectionOptions {
  includeChildren?: boolean;
  includeDescendants?: boolean;
  excludeBooked?: boolean;
}

export interface SelectionState {
  memberCount: number;
  dimensionId: string;
  isEmpty: boolean;
  isAll: boolean;
}

// ---------------------------------------------------------------------------
// Filter interfaces
// ---------------------------------------------------------------------------

export interface FilterValue {
  dimension: string;
  member?: string;
  operator?: string;
  lowValue?: string;
  highValue?: string;
  type?: FilterValueType;
}

export interface TimeRange {
  start?: string;
  end?: string;
  granularity?: TimeRangeGranularity;
  relative?: boolean;
  offset?: number;
}

export interface SortSpec {
  dimension?: string;
  measure?: string;
  direction: SortDirection;
}

export interface RankSpec {
  measure: string;
  count: number;
  direction: RankDirection;
}

export interface MembersOptions {
  offset?: number;
  limit?: number;
  displayMode?: MemberDisplayMode;
  accessMode?: MemberAccessMode;
}

// ---------------------------------------------------------------------------
// DataSource class
// Spec: datasource/datasource_client.odps.yaml
// ---------------------------------------------------------------------------

export class DataSource {
  constructor(
    private readonly client: SACRestAPIClient,
    public readonly name: string,
  ) {}

  // -- Dimension metadata ---------------------------------------------------

  async getDimensions(): Promise<DimensionInfo[]> {
    return this.client.get<DimensionInfo[]>(`/datasource/${e(this.name)}/dimensions`);
  }

  async getDimensionInfo(dimensionId: string): Promise<DimensionInfo> {
    return this.client.get<DimensionInfo>(
      `/datasource/${e(this.name)}/dimensions/${e(dimensionId)}`,
    );
  }

  // -- Measure metadata -----------------------------------------------------

  async getMeasures(): Promise<MeasureInfo[]> {
    return this.client.get<MeasureInfo[]>(`/datasource/${e(this.name)}/measures`);
  }

  async getMeasureInfo(measureId: string): Promise<MeasureInfo> {
    return this.client.get<MeasureInfo>(
      `/datasource/${e(this.name)}/measures/${e(measureId)}`,
    );
  }

  // -- Member operations ----------------------------------------------------

  async getMembers(dimensionId: string, options?: MembersOptions): Promise<MemberInfo[]> {
    const qs = options ? `?${toQuery(options as unknown as Record<string, unknown>)}` : '';
    return this.client.get<MemberInfo[]>(
      `/datasource/${e(this.name)}/dimensions/${e(dimensionId)}/members${qs}`,
    );
  }

  async getMember(dimensionId: string, memberId: string): Promise<MemberInfo> {
    return this.client.get<MemberInfo>(
      `/datasource/${e(this.name)}/dimensions/${e(dimensionId)}/members/${e(memberId)}`,
    );
  }

  async getMemberCount(dimensionId: string): Promise<number> {
    return this.client.get<number>(
      `/datasource/${e(this.name)}/dimensions/${e(dimensionId)}/memberCount`,
    );
  }

  // -- Hierarchy ------------------------------------------------------------

  async getHierarchy(dimensionId: string): Promise<HierarchyInfo> {
    return this.client.get<HierarchyInfo>(
      `/datasource/${e(this.name)}/dimensions/${e(dimensionId)}/hierarchy`,
    );
  }

  async getHierarchies(dimensionId: string): Promise<HierarchyInfo[]> {
    return this.client.get<HierarchyInfo[]>(
      `/datasource/${e(this.name)}/dimensions/${e(dimensionId)}/hierarchies`,
    );
  }

  // -- Variables ------------------------------------------------------------

  async getVariables(): Promise<VariableInfo[]> {
    return this.client.get<VariableInfo[]>(`/datasource/${e(this.name)}/variables`);
  }

  async getVariable(variableName: string): Promise<VariableInfo> {
    return this.client.get<VariableInfo>(
      `/datasource/${e(this.name)}/variables/${e(variableName)}`,
    );
  }

  async setVariableValue(variableName: string, values: VariableValue[]): Promise<OperationResult> {
    return this.client.put<OperationResult>(
      `/datasource/${e(this.name)}/variables/${e(variableName)}`, { values },
    );
  }

  async setVariableRange(variableName: string, range: VariableRange): Promise<OperationResult> {
    return this.client.put<OperationResult>(
      `/datasource/${e(this.name)}/variables/${e(variableName)}/range`, range,
    );
  }

  // -- DataSource info ------------------------------------------------------

  async getInfo(): Promise<{ name: string; modelId?: string; type?: string }> {
    return this.client.get(`/datasource/${e(this.name)}/info`);
  }

  // -- Data -----------------------------------------------------------------

  async getData(coordinates?: SelectionContext): Promise<DataCell> {
    return this.client.post<DataCell>(`/datasource/${e(this.name)}/data`, { coordinates });
  }

  async setData(
    coordinates: SelectionContext, value: number | string,
  ): Promise<OperationResult> {
    return this.client.post<OperationResult>(
      `/datasource/${e(this.name)}/data/set`, { coordinates, value },
    );
  }

  async getResultSet(): Promise<ResultSet> {
    const id = await this.client.post<{ id: string }>(
      `/datasource/${e(this.name)}/resultset`, {},
    );
    return new ResultSet(this.client, id.id, this.name);
  }

  // -- Filters --------------------------------------------------------------

  async setFilter(dimensionId: string, filter: FilterValue): Promise<OperationResult> {
    return this.client.post<OperationResult>(
      `/datasource/${e(this.name)}/filter`, { dimensionId, ...filter },
    );
  }

  async getFilter(dimensionId: string): Promise<FilterValue> {
    return this.client.get<FilterValue>(
      `/datasource/${e(this.name)}/filter/${e(dimensionId)}`,
    );
  }

  async clearFilter(dimensionId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(
      `/datasource/${e(this.name)}/filter/${e(dimensionId)}`,
    );
  }

  async clearAllFilters(): Promise<OperationResult> {
    return this.client.del<OperationResult>(`/datasource/${e(this.name)}/filters`);
  }

  async getDimensionFilters(): Promise<FilterValue[]> {
    return this.client.get<FilterValue[]>(`/datasource/${e(this.name)}/filters`);
  }

  async addMeasureFilter(measureId: string, filter: FilterValue): Promise<OperationResult> {
    return this.client.post<OperationResult>(
      `/datasource/${e(this.name)}/measurefilter`, { measureId, ...filter },
    );
  }

  async removeMeasureFilter(measureId: string): Promise<OperationResult> {
    return this.client.del<OperationResult>(
      `/datasource/${e(this.name)}/measurefilter/${e(measureId)}`,
    );
  }

  // -- Active members -------------------------------------------------------

  async getActiveMembers(dimensionId: string): Promise<MemberInfo[]> {
    return this.client.get<MemberInfo[]>(
      `/datasource/${e(this.name)}/dimensions/${e(dimensionId)}/activemembers`,
    );
  }

  async setActiveMembers(dimensionId: string, memberIds: string[]): Promise<OperationResult> {
    return this.client.put<OperationResult>(
      `/datasource/${e(this.name)}/dimensions/${e(dimensionId)}/activemembers`, { memberIds },
    );
  }

  // -- Lifecycle ------------------------------------------------------------

  async refreshData(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/datasource/${e(this.name)}/refresh`);
  }

  async pause(mode?: PauseMode): Promise<OperationResult> {
    return this.client.post<OperationResult>(
      `/datasource/${e(this.name)}/pause`, { mode: mode ?? PauseMode.On },
    );
  }

  async resume(): Promise<OperationResult> {
    return this.client.post<OperationResult>(`/datasource/${e(this.name)}/resume`);
  }

  // -- Factory --------------------------------------------------------------

  static async getDataSource(client: SACRestAPIClient, name: string): Promise<DataSource> {
    return new DataSource(client, name);
  }
}

// ---------------------------------------------------------------------------
// ResultSet — server-backed query results
// Spec: datasource/resultset_client.odps.yaml
// ---------------------------------------------------------------------------

export class ResultSet {
  constructor(
    private readonly client: SACRestAPIClient,
    private readonly rsId: string,
    private readonly dsName: string,
  ) {}

  // -- Row access -----------------------------------------------------------

  async getRows(): Promise<RowInfo[]> {
    return this.client.get<RowInfo[]>(`/datasource/${e(this.dsName)}/resultset/${e(this.rsId)}/rows`);
  }

  async getRow(index: number): Promise<RowInfo> {
    return this.client.get<RowInfo>(`/datasource/${e(this.dsName)}/resultset/${e(this.rsId)}/rows/${index}`);
  }

  async getRowCount(): Promise<number> {
    return this.client.get<number>(`/datasource/${e(this.dsName)}/resultset/${e(this.rsId)}/rowCount`);
  }

  // -- Column access --------------------------------------------------------

  async getColumns(): Promise<ColumnInfo[]> {
    return this.client.get<ColumnInfo[]>(`/datasource/${e(this.dsName)}/resultset/${e(this.rsId)}/columns`);
  }

  async getColumn(index: number): Promise<ColumnInfo> {
    return this.client.get<ColumnInfo>(`/datasource/${e(this.dsName)}/resultset/${e(this.rsId)}/columns/${index}`);
  }

  async getColumnCount(): Promise<number> {
    return this.client.get<number>(`/datasource/${e(this.dsName)}/resultset/${e(this.rsId)}/columnCount`);
  }

  // -- Cell access ----------------------------------------------------------

  async getCell(rowIndex: number, columnIndex: number): Promise<CellInfo> {
    return this.client.get<CellInfo>(
      `/datasource/${e(this.dsName)}/resultset/${e(this.rsId)}/cell/${rowIndex}/${columnIndex}`,
    );
  }

  async getCellValue(rowIndex: number, columnIndex: number): Promise<unknown> {
    return this.client.get(
      `/datasource/${e(this.dsName)}/resultset/${e(this.rsId)}/cell/${rowIndex}/${columnIndex}/value`,
    );
  }

  async getFormattedValue(rowIndex: number, columnIndex: number): Promise<string> {
    return this.client.get<string>(
      `/datasource/${e(this.dsName)}/resultset/${e(this.rsId)}/cell/${rowIndex}/${columnIndex}/formatted`,
    );
  }

  // -- Metadata -------------------------------------------------------------

  async getMetadata(): Promise<ResultSetMetadata> {
    return this.client.get<ResultSetMetadata>(
      `/datasource/${e(this.dsName)}/resultset/${e(this.rsId)}/metadata`,
    );
  }

  async hasMoreRows(): Promise<boolean> {
    return this.client.get<boolean>(
      `/datasource/${e(this.dsName)}/resultset/${e(this.rsId)}/hasMoreRows`,
    );
  }
}

// ---------------------------------------------------------------------------
// Selection — member set for filtering/navigation
// Spec: datasource/selection_client.odps.yaml
// ---------------------------------------------------------------------------

export class Selection {
  constructor(
    private readonly client: SACRestAPIClient,
    private readonly selectionId: string,
    public readonly dimensionId: string,
  ) {}

  // -- Member access --------------------------------------------------------

  async getMembers(): Promise<SelectionMember[]> {
    return this.client.get<SelectionMember[]>(`/selection/${e(this.selectionId)}/members`);
  }

  async getMemberIds(): Promise<string[]> {
    return this.client.get<string[]>(`/selection/${e(this.selectionId)}/memberIds`);
  }

  async contains(memberId: string): Promise<boolean> {
    return this.client.get<boolean>(`/selection/${e(this.selectionId)}/contains/${e(memberId)}`);
  }

  async getCount(): Promise<number> {
    return this.client.get<number>(`/selection/${e(this.selectionId)}/count`);
  }

  // -- Modification ---------------------------------------------------------

  async add(memberId: string, options?: SelectionOptions): Promise<Selection> {
    await this.client.post(`/selection/${e(this.selectionId)}/add`, { memberId, options });
    return this;
  }

  async addRange(range: SelectionRange): Promise<Selection> {
    await this.client.post(`/selection/${e(this.selectionId)}/addRange`, range);
    return this;
  }

  async remove(memberId: string): Promise<Selection> {
    await this.client.post(`/selection/${e(this.selectionId)}/remove`, { memberId });
    return this;
  }

  async clear(): Promise<Selection> {
    await this.client.post(`/selection/${e(this.selectionId)}/clear`);
    return this;
  }

  async setAll(): Promise<Selection> {
    await this.client.post(`/selection/${e(this.selectionId)}/setAll`);
    return this;
  }

  async invert(): Promise<Selection> {
    await this.client.post(`/selection/${e(this.selectionId)}/invert`);
    return this;
  }

  // -- Set operations -------------------------------------------------------

  async union(other: Selection): Promise<Selection> {
    const res = await this.client.post<{ id: string }>(
      `/selection/${e(this.selectionId)}/union`, { otherId: other.selectionId },
    );
    return new Selection(this.client, res.id, this.dimensionId);
  }

  async intersect(other: Selection): Promise<Selection> {
    const res = await this.client.post<{ id: string }>(
      `/selection/${e(this.selectionId)}/intersect`, { otherId: other.selectionId },
    );
    return new Selection(this.client, res.id, this.dimensionId);
  }

  async subtract(other: Selection): Promise<Selection> {
    const res = await this.client.post<{ id: string }>(
      `/selection/${e(this.selectionId)}/subtract`, { otherId: other.selectionId },
    );
    return new Selection(this.client, res.id, this.dimensionId);
  }

  // -- State ----------------------------------------------------------------

  async getState(): Promise<SelectionState> {
    return this.client.get<SelectionState>(`/selection/${e(this.selectionId)}/state`);
  }

  async clone(): Promise<Selection> {
    const res = await this.client.post<{ id: string }>(`/selection/${e(this.selectionId)}/clone`);
    return new Selection(this.client, res.id, this.dimensionId);
  }

  async toFilter(): Promise<FilterValue> {
    return this.client.get<FilterValue>(`/selection/${e(this.selectionId)}/toFilter`);
  }

  // -- Factory --------------------------------------------------------------

  static async createSelection(
    client: SACRestAPIClient, dimensionId: string,
  ): Promise<Selection> {
    const res = await client.post<{ id: string }>('/selection/create', { dimensionId });
    return new Selection(client, res.id, dimensionId);
  }

  static async createFromMembers(
    client: SACRestAPIClient, dimensionId: string, memberIds: string[],
  ): Promise<Selection> {
    const res = await client.post<{ id: string }>(
      '/selection/create', { dimensionId, memberIds },
    );
    return new Selection(client, res.id, dimensionId);
  }
}

// ---------------------------------------------------------------------------
// Event type maps (Rule 8)
// ---------------------------------------------------------------------------

export interface DataSourceEvents {
  dataChanged: () => void;
  filterChanged: (dimensionId: string) => void;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function e(s: string): string { return encodeURIComponent(s); }

function toQuery(obj: Record<string, unknown>): string {
  return Object.entries(obj)
    .filter(([, v]) => v != null)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
    .join('&');
}

// ---------------------------------------------------------------------------
// Re-exports
// ---------------------------------------------------------------------------

export { SortDirection, RankDirection, PauseMode } from '../types';
export type { FilterValueType, VariableValueType, MemberDisplayMode, MemberAccessMode, TimeRangeGranularity } from '../types';
