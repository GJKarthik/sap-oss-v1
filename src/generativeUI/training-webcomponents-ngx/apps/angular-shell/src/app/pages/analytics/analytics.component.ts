import { Component, ChangeDetectionStrategy, inject, signal, OnInit, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { I18nService } from '../../services/i18n.service';
import { VectorService, VectorStore } from '../../services/vector.service';
import { ToastService } from '../../services/toast.service';
import { LocaleNumberPipe } from '../../shared/pipes/locale-number.pipe';
import { LocaleDatePipe } from '../../shared/pipes/locale-date.pipe';

@Component({
  selector: 'app-analytics',
  standalone: true,
  imports: [CommonModule, FormsModule, LocaleNumberPipe, LocaleDatePipe],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './analytics.component.html',
  styleUrls: ['./analytics.component.scss']
})
export class AnalyticsComponent implements OnInit {
  readonly i18n = inject(I18nService);
  private readonly vector = inject(VectorService);
  private readonly toast = inject(ToastService);

  readonly vectorStores = signal<VectorStore[]>([]);
  readonly selectedStore = signal<string | null>(null);
  readonly analyticsData = signal<any>(null);
  readonly isLoading = signal(false);

  ngOnInit(): void {
    this.loadStores();
  }

  loadStores(): void {
    this.vector.fetchStores().subscribe({
      next: (stores) => {
        this.vectorStores.set(stores);
        if (stores.length > 0 && !this.selectedStore()) {
          this.onStoreChange(stores[0].table_name);
        }
      },
      error: () => this.toast.error(this.i18n.t('search.error.loadStores'))
    });
  }

  onStoreChange(tableName: string): void {
    this.selectedStore.set(tableName);
    this.loadAnalytics(tableName);
  }

  loadAnalytics(tableName: string): void {
    this.isLoading.set(true);
    this.vector.fetchAnalytics(tableName).subscribe({
      next: (data) => {
        this.analyticsData.set(data);
        this.isLoading.set(false);
      },
      error: () => {
        this.isLoading.set(false);
        this.toast.error(this.i18n.t('analytics.error.loadFailed'));
      }
    });
  }

  getTrendClass(value: number): string {
    return value >= 0 ? 'trend-up' : 'trend-down';
  }
}
