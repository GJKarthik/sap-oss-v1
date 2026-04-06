import { Injectable } from '@angular/core';
import { Subject } from 'rxjs';

export interface UIIntent {
  action: string;
  payload?: any;
  sourceType?: string;
}

@Injectable({
  providedIn: 'root'
})
export class GenerativeIntentService {
  private intentSubject = new Subject<UIIntent>();
  
  // Observable for the Page to listen to Bubbled Intents
  intents$ = this.intentSubject.asObservable();

  // Dispatch an intent back to the root
  dispatch(intent: UIIntent) {
    this.intentSubject.next(intent);
  }
}
