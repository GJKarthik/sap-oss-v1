// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * SAC Translate Pipe
 *
 * Usage in templates:
 *   {{ 'chat.ask' | sacTranslate }}
 *   {{ 'chat.risk' | sacTranslate:{ level: riskLevel } }}
 */

import {
  ChangeDetectorRef,
  inject,
  OnDestroy,
  Pipe,
  PipeTransform,
} from '@angular/core';
import { Subscription } from 'rxjs';

import { SacI18nService } from '../services/sac-i18n.service';

@Pipe({
  name: 'sacTranslate',
  standalone: true,
  pure: false,
})
export class SacTranslatePipe implements PipeTransform, OnDestroy {
  private lastKey = '';
  private lastParams: Record<string, string | number> | undefined;
  private value = '';
  private subscription: Subscription;

  private readonly i18n = inject(SacI18nService);
  private readonly cdr = inject(ChangeDetectorRef);

  constructor() {
    this.subscription = this.i18n.locale$.subscribe(() => {
      this.updateValue();
    });
  }

  ngOnDestroy(): void {
    this.subscription.unsubscribe();
  }

  transform(key: string, params?: Record<string, string | number>): string {
    if (key !== this.lastKey || params !== this.lastParams) {
      this.lastKey = key;
      this.lastParams = params;
      this.updateValue();
    }
    return this.value;
  }

  private updateValue(): void {
    if (this.lastKey) {
      this.value = this.i18n.t(this.lastKey, this.lastParams);
      this.cdr.markForCheck();
    }
  }
}
