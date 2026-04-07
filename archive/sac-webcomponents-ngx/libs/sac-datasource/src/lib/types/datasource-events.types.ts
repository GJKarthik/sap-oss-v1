/**
 * DataSource event types — from sap-sac-webcomponents-ts/src/datasource
 */

export interface DataSourceEvents {
  onDataLoaded?: (event: DataLoadedEvent) => void;
  onFilterChanged?: (event: FilterChangedEvent) => void;
  onVariableChanged?: (event: VariableChangedEvent) => void;
  onSelectionChanged?: (event: SelectionChangedEvent) => void;
}

export interface DataLoadedEvent {
  dataSourceId: string;
  rowCount: number;
  duration: number;
}

export interface FilterChangedEvent {
  dimensionId: string;
  filterType: string;
  values: unknown[];
}

export interface VariableChangedEvent {
  variableId: string;
  value: unknown;
  previousValue?: unknown;
}

export interface SelectionChangedEvent {
  selectionId: string;
  members: string[];
  previousMembers?: string[];
}
