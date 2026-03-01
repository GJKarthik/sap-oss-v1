import type { DataRepository } from './data-repository.js';
/**
 * Representation of the 'DataRepositories' schema.
 */
export type DataRepositories = {
    count?: number;
    resources: DataRepository[];
} & Record<string, any>;
//# sourceMappingURL=data-repositories.d.ts.map