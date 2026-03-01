import type { ColumnType } from './column-type.js';
/**
 * Configuration for a single field in the input data schema.
 */
export type SchemaFieldConfig = {
    dtype: ColumnType;
} & Record<string, any>;
//# sourceMappingURL=schema-field-config.d.ts.map