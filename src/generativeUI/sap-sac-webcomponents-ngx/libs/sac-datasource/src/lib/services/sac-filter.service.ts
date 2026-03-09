import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';
import type { FilterValue } from '../types/filter.types';

@Injectable({ providedIn: 'root' })
export class SacFilterService {
  private readonly activeFilters$ = new BehaviorSubject<Map<string, FilterValue[]>>(new Map());

  get filters$(): Observable<Map<string, FilterValue[]>> {
    return this.activeFilters$.asObservable();
  }

  setFilter(dimensionId: string, values: FilterValue[]): void {
    const current = new Map(this.activeFilters$.value);
    current.set(dimensionId, values);
    this.activeFilters$.next(current);
  }

  removeFilter(dimensionId: string): void {
    const current = new Map(this.activeFilters$.value);
    current.delete(dimensionId);
    this.activeFilters$.next(current);
  }

  clearAll(): void {
    this.activeFilters$.next(new Map());
  }

  getFilter(dimensionId: string): FilterValue[] | undefined {
    return this.activeFilters$.value.get(dimensionId);
  }
}
