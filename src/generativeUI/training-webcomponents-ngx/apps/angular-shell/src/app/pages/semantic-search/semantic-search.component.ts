import { Component, ChangeDetectionStrategy, inject, signal, OnInit, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { I18nService } from '../../services/i18n.service';
import { VectorService, VectorStore, VectorQueryResponse } from '../../services/vector.service';
import { ToastService } from '../../services/toast.service';
import { LocaleNumberPipe } from '../../shared/pipes/locale-number.pipe';

@Component({
  selector: 'app-semantic-search',
  standalone: true,
  imports: [CommonModule, FormsModule, LocaleNumberPipe],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './semantic-search.component.html',
  styleUrls: ['./semantic-search.component.scss']
})
export class SemanticSearchComponent implements OnInit {
  readonly i18n = inject(I18nService);
  private readonly vector = inject(VectorService);
  private readonly toast = inject(ToastService);

  readonly vectorStores = signal<VectorStore[]>([]);
  readonly selectedStore = signal<string | null>(null);
  readonly queryText = signal('');
  readonly isSearching = signal(false);
  readonly searchResult = signal<VectorQueryResponse | null>(null);
  readonly searchHistory = signal<{query: string, ts: Date}[]>([]);

  ngOnInit(): void {
    this.loadStores();
  }

  loadStores(): void {
    this.vector.fetchStores().subscribe({
      next: (stores) => {
        this.vectorStores.set(stores);
        if (stores.length > 0 && !this.selectedStore()) {
          this.selectedStore.set(stores[0].table_name);
        }
      },
      error: () => this.toast.error(this.i18n.t('search.error.loadStores'))
    });
  }

  onSearch(): void {
    const query = this.queryText().trim();
    const table = this.selectedStore();
    if (!query || !table || this.isSearching()) return;

    this.isSearching.set(true);
    this.vector.query(query, table).subscribe({
      next: (res) => {
        this.searchResult.set(res);
        this.isSearching.set(false);
        this.searchHistory.update(h => [{query, ts: new Date()}, ...h].slice(0, 10));
      },
      error: () => {
        this.isSearching.set(false);
        this.toast.error(this.i18n.t('search.error.queryFailed'));
      }
    });
  }

  useHistory(query: string): void {
    this.queryText.set(query);
    this.onSearch();
  }

  clearResults(): void {
    this.searchResult.set(null);
    this.queryText.set('');
  }
}
