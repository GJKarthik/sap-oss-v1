import { Injectable } from '@angular/core';
import { Subject, Observable } from 'rxjs';
import { filter } from 'rxjs/operators';

@Injectable()
export class SacEventService {
  private readonly events$ = new Subject<{ type: string; payload: unknown }>();

  emit(type: string, payload?: unknown): void {
    this.events$.next({ type, payload });
  }

  on(type: string): Observable<{ type: string; payload: unknown }> {
    return this.events$.pipe(filter((e) => e.type === type));
  }

  onAny(): Observable<{ type: string; payload: unknown }> {
    return this.events$.asObservable();
  }
}
