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
      }
    });
  }

  approveEntry(entry: TMEntry): void {
    const updated = { ...entry, is_approved: true };
    this.tm.save(updated).subscribe({
      next: () => {
        this.loadTM();
        this.glossary.loadOverrides();
      }
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
}
