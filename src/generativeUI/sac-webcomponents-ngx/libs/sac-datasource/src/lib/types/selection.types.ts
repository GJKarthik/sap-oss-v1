/**
 * Selection Types
 * Derived from mangle/sac_datasource.mg
 */

export interface Selection {
  dimensionId: string;
  members: SelectionMember[];
  context?: SelectionContext;
}

export interface SelectionContext {
  dataSourceId: string;
  dimensionId: string;
  hierarchyId?: string;
}

export interface SelectionMember {
  id: string;
  description?: string;
  level?: number;
  parentId?: string;
}

export interface SelectionRange {
  from: string;
  to: string;
  dimensionId: string;
}

export interface SelectionOptions {
  multiSelect?: boolean;
  hierarchyNavigation?: boolean;
  searchEnabled?: boolean;
  maxSelections?: number;
}
