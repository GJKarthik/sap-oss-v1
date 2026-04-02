import { Injectable } from '@angular/core';
import { BehaviorSubject, Observable } from 'rxjs';

export interface VariableValue {
  variableId: string;
  value: unknown;
  type: string;
}

@Injectable({ providedIn: 'root' })
export class SacVariableService {
  private readonly variables$ = new BehaviorSubject<Map<string, VariableValue>>(new Map());

  get variableValues$(): Observable<Map<string, VariableValue>> {
    return this.variables$.asObservable();
  }

  setVariable(variableId: string, value: unknown, type = 'single'): void {
    const current = new Map(this.variables$.value);
    current.set(variableId, { variableId, value, type });
    this.variables$.next(current);
  }

  getVariable(variableId: string): VariableValue | undefined {
    return this.variables$.value.get(variableId);
  }

  removeVariable(variableId: string): void {
    const current = new Map(this.variables$.value);
    current.delete(variableId);
    this.variables$.next(current);
  }

  clearAll(): void {
    this.variables$.next(new Map());
  }
}
