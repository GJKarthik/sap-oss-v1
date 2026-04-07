/**
 * @sap-oss/sac-webcomponents-ngx/datasource
 *
 * Angular DataSource Module for SAP Analytics Cloud data operations.
 * Derived from mangle/sac_datasource.mg specifications.
 */

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

export { SacDataSourceModule } from './lib/sac-datasource.module';

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

export { SacDataSourceService } from './lib/services/sac-datasource.service';
export { SacFilterService } from './lib/services/sac-filter.service';
export { SacVariableService } from './lib/services/sac-variable.service';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type {
  DataSource,
  DataSourceConfig,
  DataSourceState,
  ResultSet,
  ResultSetMetadata,
  DataCell,
  CellStatus,
} from './lib/types/datasource.types';

export type {
  DimensionInfo,
  DimensionPropertyInfo,
  MeasureInfo,
  MemberInfo,
  HierarchyInfo,
  VariableInfo,
  VariableValue,
} from './lib/types/metadata.types';

export type {
  FilterValue,
  SingleFilterValue,
  MultipleFilterValue,
  RangeFilterValue,
  FilterConfig,
} from './lib/types/filter.types';

export type {
  Selection,
  SelectionContext,
  SelectionMember,
  SelectionRange,
  SelectionOptions,
} from './lib/types/selection.types';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

export type {
  DataSourceEvents,
  DataLoadedEvent,
  FilterChangedEvent,
  VariableChangedEvent,
  SelectionChangedEvent,
} from './lib/types/datasource-events.types';
