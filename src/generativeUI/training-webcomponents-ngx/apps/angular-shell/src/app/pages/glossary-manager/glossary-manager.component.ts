import { Component, ChangeDetectionStrategy, inject, signal, OnInit, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { I18nService } from '../../services/i18n.service';
import { GlossaryService } from '../../services/glossary.service';
import { TranslationMemoryService, TMEntry, TMBackendMeta } from '../../services/translation-memory.service';
import { ToastService } from '../../services/toast.service';

@Component({
  selector: 'app-glossary-manager',
  standalone: true,
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './glossary-manager.component.html',
  styleUrls: ['./glossary-manager.component.scss']
})
export class GlossaryManagerComponent implements OnInit {
  readonly i18n = inject(I18nService);
  readonly glossary = inject(GlossaryService);
  private readonly tm = inject(TranslationMemoryService);
  private readonly toast = inject(ToastService);

  readonly tmEntries = signal<TMEntry[]>([]);
  readonly isLoading = signal(false);
  readonly showAddForm = signal(false);
  readonly tmBackend = signal<TMBackendMeta['backend']>('sqlite');
  searchQuery = '';

  newEntry: TMEntry = {
    source_text: '',
    target_text: '',
    source_lang: 'en',
    target_lang: 'ar',
    category: 'financial',
    is_approved: true
  };

  ngOnInit(): void {
    this.loadTM();
    this.loadTMMeta();
  }

  loadTM(): void {
    this.isLoading.set(true);
    this.tm.list().subscribe({
      next: (entries) => {
        this.tmEntries.set(entries);
        this.isLoading.set(false);
      },
      error: () => {
        this.isLoading.set(false);
        this.toast.error(this.i18n.t('glossary.error.loadFailed'));
      }
    });
  }

  loadTMMeta(): void {
    this.tm.getMeta().subscribe({
      next: (meta) => this.tmBackend.set(meta.backend),
      error: () => this.tmBackend.set('sqlite')
    });
  }

  saveNewEntry(): void {
    if (!this.newEntry.source_text || !this.newEntry.target_text) return;

    this.tm.save(this.newEntry).subscribe({
      next: () => {
        this.toast.success(this.i18n.t('chat.tmSaved'));
        this.showAddForm.set(false);
        this.resetForm();
        this.loadTM();
        this.glossary.loadOverrides();
      },
      error: () => this.toast.error(this.i18n.t('chat.tmError'))
    });
  }

  deleteEntry(id: string | undefined): void {
    if (!id) return;
    this.tm.delete(id).subscribe({
      next: () => {
        this.toast.success(this.i18n.t('glossary.deleted'));
        this.loadTM();
        this.glossary.loadOverrides();
      },
      error: () => this.toast.error(this.i18n.t('glossary.deleteFailed'))
    });
  }

  approveEntry(entry: TMEntry): void {
    const updated = { ...entry, is_approved: true };
    this.tm.save(updated).subscribe({
      next: () => {
        this.loadTM();
        this.glossary.loadOverrides();
      },
      error: () => this.toast.error(this.i18n.t('glossary.approveFailed'))
    });
  }

  resetForm(): void {
    this.newEntry = {
      source_text: '',
      target_text: '',
      source_lang: 'en',
      target_lang: 'ar',
      category: 'financial',
      is_approved: true
    };
  }

  tmBackendLabel(): string {
    return this.tmBackend() === 'hana'
      ? this.i18n.t('glossary.backend.hana')
      : this.i18n.t('glossary.backend.sqlite');
  }

  filteredTmEntries(): TMEntry[] {
    if (!this.searchQuery) return this.tmEntries();
    const q = this.searchQuery.toLowerCase();
    return this.tmEntries().filter(e =>
      e.source_text.toLowerCase().includes(q) ||
      e.target_text.toLowerCase().includes(q) ||
      (e.category?.toLowerCase().includes(q))
    );
  }

  exportJson(): void {
    const data = this.tmEntries();
    if (data.length === 0) return;
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a'); a.href = url; a.download = 'glossary-overrides.json'; a.click();
    URL.revokeObjectURL(url);
  }

  onImport(event: Event): void {
    const file = (event.target as HTMLInputElement)?.files?.[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        const entries: TMEntry[] = JSON.parse(reader.result as string);
        if (!Array.isArray(entries)) { this.toast.error(this.i18n.t('glossary.invalidFileFormat')); return; }
        let saved = 0;
        entries.forEach(entry => {
          if (entry.source_text && entry.target_text) {
            this.tm.save(entry).subscribe({ next: () => { saved++; if (saved === entries.length) { this.loadTM(); this.glossary.loadOverrides(); this.toast.success(this.i18n.t('glossary.importedEntries', { count: String(saved) })); } } });
          }
        });
      } catch { this.toast.error(this.i18n.t('glossary.failedParseFile')); }
    };
    reader.readAsText(file);
    (event.target as HTMLInputElement).value = '';
  }
}
