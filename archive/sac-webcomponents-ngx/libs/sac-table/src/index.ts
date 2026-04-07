/**
 * @sap-oss/sac-webcomponents-ngx/table
 *
 * Angular Table Module for SAP Analytics Cloud data grids.
 * Selector derived from mangle: angular_selector("Table", "sac-table")
 */

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

export { SacTableModule } from './lib/sac-table.module';

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

export { SacTableComponent } from './lib/components/sac-table.component';

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

export { SacTableService } from './lib/services/sac-table.service';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type {
  TableConfig,
  TableColumn,
  TableRow,
  TableCell,
  TableSelection,
  TableSortConfig,
  TableFilterConfig,
  TablePaginationConfig,
} from './lib/types/table.types';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

export type {
  TableCellClickEvent,
  TableRowClickEvent,
  TableSelectionChangeEvent,
  TableSortChangeEvent,
  TablePageChangeEvent,
} from './lib/types/table-events.types';
