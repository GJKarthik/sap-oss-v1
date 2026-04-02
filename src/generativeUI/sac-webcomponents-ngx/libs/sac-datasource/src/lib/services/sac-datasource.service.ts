/**
 * SAC DataSource Service
 *
 * Service for managing SAC datasource operations.
 * Derived from mangle/sac_datasource.mg service_method facts.
 */

import { Injectable, inject } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';

import { SacApiService } from '@sap-oss/sac-ngx-core';
import type {
  DataSource,
  DataSourceConfig,
  DataSourceState,
  ResultSet,
} from '../types/datasource.types';
import type { DimensionInfo, MeasureInfo, VariableInfo } from '../types/metadata.types';
import type { FilterValue } from '../types/filter.types';

@Injectable({ providedIn: 'root' })
export class SacDataSourceService {
  private dataSources = new Map<string, DataSourceInstance>();
  private readonly api = inject(SacApiService);

  /**
   * Create a new datasource instance.
   * Implements: service_method("DataSource", "getData", "ResultSet", "async")
   */
  create(modelId: string, config?: Partial<DataSourceConfig>): DataSourceInstance {
    const id = `ds_${modelId}_${Date.now()}`;
    const instance = new DataSourceInstance(id, modelId, this.api, config);
    this.dataSources.set(id, instance);
    return instance;
  }

  /**
   * Get an existing datasource by ID.
   */
  get(id: string): DataSourceInstance | undefined {
    return this.dataSources.get(id);
  }

  /**
   * Destroy a datasource instance.
   */
  destroy(id: string): void {
    const instance = this.dataSources.get(id);
    if (instance) {
      instance.dispose();
      this.dataSources.delete(id);
    }
  }

  /**
   * Get all active datasource IDs.
   */
  getActiveIds(): string[] {
    return Array.from(this.dataSources.keys());
  }
}

/**
 * Individual DataSource instance.
 */
export class DataSourceInstance implements DataSource {
  readonly id: string;
  readonly modelId: string;

  private readonly data$ = new BehaviorSubject<ResultSet | null>(null);
  private readonly loading$ = new BehaviorSubject<boolean>(false);
  private readonly error$ = new BehaviorSubject<Error | null>(null);
  private readonly filters$ = new BehaviorSubject<Map<string, FilterValue>>(new Map());

  private dimensions: DimensionInfo[] = [];
  private measures: MeasureInfo[] = [];
  private variables: VariableInfo[] = [];
  private paused = false;
  private lastRefreshAt?: Date;

  constructor(
    id: string,
    modelId: string,
    private readonly api: SacApiService,
    private config?: Partial<DataSourceConfig>,
  ) {
    this.id = id;
    this.modelId = modelId;

    if (config?.initialFilters) {
      this.filters$.next(new Map(Object.entries(config.initialFilters)));
    }
  }

  get resultSet$(): Observable<ResultSet | null> {
    return this.data$.asObservable();
  }

  get isLoading$(): Observable<boolean> {
    return this.loading$.asObservable();
  }

  get lastError$(): Observable<Error | null> {
    return this.error$.asObservable();
  }

  get activeFilters$(): Observable<Map<string, FilterValue>> {
    return this.filters$.asObservable();
  }

  /**
   * Get data from the datasource.
   * Implements: service_method("DataSource", "getData", "ResultSet", "async")
   */
  async getData(): Promise<ResultSet> {
    if (this.paused) {
      const current = this.data$.getValue();
      if (current) return current;
      throw new Error('DataSource is paused and has no cached data');
    }

    this.loading$.next(true);
    this.error$.next(null);

    try {
      const response = await this.api.post<ResultSet>(
        this.buildApiPath('/data'),
        {
          modelId: this.modelId,
          filters: Object.fromEntries(this.filters$.getValue()),
        },
      );

      this.lastRefreshAt = new Date();
      this.data$.next(response);
      return response;
    } catch (error) {
      const normalised = this.toError(error, 'Failed to load datasource data');
      this.error$.next(normalised);
      throw normalised;
    } finally {
      this.loading$.next(false);
    }
  }

  getDimensions(): DimensionInfo[] {
    return [...this.dimensions];
  }

  getMeasures(): MeasureInfo[] {
    return [...this.measures];
  }

  getVariables(): VariableInfo[] {
    return [...this.variables];
  }

  async setFilter(dimension: string, value: FilterValue): Promise<void> {
    const filters = new Map(this.filters$.getValue());
    filters.set(dimension, value);
    this.filters$.next(filters);

    if (!this.paused) {
      await this.getData();
    }
  }

  async removeFilter(dimension: string): Promise<void> {
    const filters = new Map(this.filters$.getValue());
    filters.delete(dimension);
    this.filters$.next(filters);

    if (!this.paused) {
      await this.getData();
    }
  }

  async clearFilters(): Promise<void> {
    this.filters$.next(new Map());

    if (!this.paused) {
      await this.getData();
    }
  }

  getActiveFilters(): FilterValue[] {
    return Array.from(this.filters$.getValue().values());
  }

  async refresh(): Promise<void> {
    await this.getData();
  }

  pause(): void {
    this.paused = true;
  }

  resume(): void {
    this.paused = false;
  }

  getState(): DataSourceState {
    return {
      id: this.id,
      modelId: this.modelId,
      paused: this.paused,
      loading: this.loading$.getValue(),
      hasData: this.data$.getValue() !== null,
      filterCount: this.filters$.getValue().size,
      lastRefresh: this.lastRefreshAt,
      error: this.error$.getValue() ?? undefined,
    };
  }

  dispose(): void {
    this.data$.complete();
    this.loading$.complete();
    this.error$.complete();
    this.filters$.complete();
  }

  private buildApiPath(endpoint: string): string {
    const suffix = endpoint.startsWith('/') ? endpoint : `/${endpoint}`;
    return `/api/v1/datasources/${encodeURIComponent(this.modelId)}${suffix}`;
  }

  private toError(error: unknown, fallbackMessage: string): Error {
    if (error instanceof Error) {
      return error;
    }

    return new Error(fallbackMessage);
  }
}
