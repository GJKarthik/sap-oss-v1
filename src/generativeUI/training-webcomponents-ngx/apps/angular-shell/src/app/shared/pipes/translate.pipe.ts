/**
 * TranslatePipe — compatibility adapter for AI Fabric pages ported into Training.
 *
 * AI Fabric pages use `{{ 'key' | translate }}` syntax.
 * This pipe delegates to Training's I18nService.t().
 */
import { Pipe, PipeTransform, inject } from '@angular/core';
import { I18nService } from '../../services/i18n.service';

@Pipe({ name: 'translate', standalone: true, pure: false })
export class TranslatePipe implements PipeTransform {
  private readonly i18n = inject(I18nService);

  transform(key: string, params?: Record<string, unknown>): string {
    return params ? this.i18n.t(key, params) : this.i18n.t(key);
  }
}
