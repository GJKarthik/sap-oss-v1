import {
  Component,
  ChangeDetectionStrategy,
  inject,
  signal,
  computed,
  CUSTOM_ELEMENTS_SCHEMA,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';

import { I18nService } from '../../services/i18n.service';
import { IngestionService } from '../../services/ingestion.service';
import { ToastService } from '../../services/toast.service';
import { PairType, TrustLevel, TermPair, ParagraphPair } from './pair-studio.types';
import { AppStore } from '../../store/app.store';
import { ConfirmationDialogComponent, type ConfirmationDialogData } from '../../shared/components/confirmation-dialog/confirmation-dialog.component';
import type { AppMode } from '../../shared/utils/mode.types';

@Component({
  selector: 'app-pair-studio',
  standalone: true,
  imports: [CommonModule, FormsModule, ConfirmationDialogComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './pair-studio.component.html',
  styleUrls: ['./pair-studio.component.scss'],
})
export class PairStudioComponent {
  readonly i18n = inject(I18nService);
  readonly ingestion = inject(IngestionService);
  readonly store = inject(AppStore);
  private readonly toast = inject(ToastService);

  // ---------------------------------------------------------------------------
  // Upload zone state
  // ---------------------------------------------------------------------------
  pairType: PairType = 'translation';
  sourceLang = 'auto';
  targetLang = 'auto';
  trustLevel: TrustLevel = 'review_first';
  droppedFiles = signal<File[]>([]);
  isDragOver = signal(false);

  // ---------------------------------------------------------------------------
  // Review table state
  // ---------------------------------------------------------------------------
  activeTab = signal<'terms' | 'paragraphs'>('terms');
  selectedTermIndices = signal<Set<number>>(new Set());
  selectedParagraphIndices = signal<Set<number>>(new Set());
  editingTermIndex = signal<number | null>(null);
  editingTargetTerm = signal('');

  // Filter state
  filterPairType = signal<string>('all');
  filterCategory = signal<string>('all');
  filterStatus = signal<string>('all');
  filterConfMin = signal<number>(0);

  // Commit state
  commitToTm = true;
  commitToGlossary = true;
  commitToVector = false;
  committing = signal(false);
  commitConfirmationOpen = signal(false);

  // ---------------------------------------------------------------------------
  // Computed
  // ---------------------------------------------------------------------------

  readonly batch = this.ingestion.currentBatch;
  readonly processing = this.ingestion.processing;
  readonly progress = this.ingestion.progress;
  readonly progressLabel = this.ingestion.progressLabel;
  readonly commitResult = this.ingestion.lastCommitResult;
  readonly activeMode = this.store.activeMode;

  readonly canProcess = computed(() => this.droppedFiles().length > 0 && !this.processing());
  readonly processButtonLabel = computed(() =>
    this.activeMode() === 'chat' ? 'Review extracted pairs' : this.i18n.t('pairStudio.processFiles'),
  );
  readonly commitButtonLabel = computed(() => {
    const labels: Record<AppMode, string> = {
      chat: 'Switch to training',
      cowork: 'Approve and commit',
      training: this.i18n.t('pairStudio.commitButton'),
    };
    return labels[this.activeMode()];
  });
  readonly modeBanner = computed(() => {
    const banners: Record<AppMode, { title: string; body: string; actionLabel: string }> = {
      chat: {
        title: 'Chat mode is read-only for commit actions.',
        body: 'You can inspect extracted pairs here, but writing to translation memory or glossary requires training mode.',
        actionLabel: 'Enable training mode',
      },
      cowork: {
        title: 'Cowork mode requires explicit approval.',
        body: 'Processing stays available, but commits will open a confirmation step before any shared data is changed.',
        actionLabel: 'Keep cowork mode',
      },
      training: {
        title: 'Training mode is live.',
        body: 'Approved pairs can be committed directly into shared translation memory and glossary stores.',
        actionLabel: 'Training ready',
      },
    };
    return banners[this.activeMode()];
  });
  readonly commitConfirmationData = computed<ConfirmationDialogData>(() => ({
    title: 'Confirm Pair Studio commit',
    message: 'Cowork mode requires approval before glossary or translation memory entries are written. Continue with this batch commit?',
    confirmText: 'Commit batch',
    cancelText: 'Keep reviewing',
    confirmDesign: 'Positive',
    icon: 'accept',
  }));

  readonly filteredTerms = computed(() => {
    const batch = this.batch();
    if (!batch) return [];
    let terms = batch.termPairs;
    const pt = this.filterPairType();
    const cat = this.filterCategory();
    const st = this.filterStatus();
    const confMin = this.filterConfMin();

    if (pt !== 'all') terms = terms.filter((t) => t.pairType === pt);
    if (cat !== 'all') terms = terms.filter((t) => t.category === cat);
    if (st !== 'all') terms = terms.filter((t) => t.status === st);
    if (confMin > 0) terms = terms.filter((t) => t.confidence >= confMin);
    return terms;
  });

  readonly filteredParagraphs = computed(() => {
    const batch = this.batch();
    if (!batch) return [];
    let paras = batch.paragraphPairs;
    const st = this.filterStatus();
    const confMin = this.filterConfMin();

    if (st !== 'all') paras = paras.filter((p) => p.status === st);
    if (confMin > 0) paras = paras.filter((p) => p.confidence >= confMin);
    return paras;
  });

  readonly categories = computed(() => {
    const batch = this.batch();
    if (!batch) return [];
    const cats = new Set(batch.termPairs.map((t) => t.category));
    return [...cats].sort();
  });

  readonly newGlossaryCount = computed(() => {
    const batch = this.batch();
    if (!batch) return 0;
    return batch.termPairs.filter((t) => t.status === 'approved' && !t.existsInGlossary).length;
  });

  readonly updatedEntryCount = computed(() => {
    const batch = this.batch();
    if (!batch) return 0;
    return batch.termPairs.filter((t) => t.status === 'approved' && t.existsInGlossary).length;
  });

  // ---------------------------------------------------------------------------
  // Upload zone handlers
  // ---------------------------------------------------------------------------

  onDragOver(event: DragEvent): void {
    event.preventDefault();
    event.stopPropagation();
    this.isDragOver.set(true);
  }

  onDragLeave(event: DragEvent): void {
    event.preventDefault();
    event.stopPropagation();
    this.isDragOver.set(false);
  }

  onDrop(event: DragEvent): void {
    event.preventDefault();
    event.stopPropagation();
    this.isDragOver.set(false);
    const files = event.dataTransfer?.files;
    if (files) {
      this.addFiles(Array.from(files));
    }
  }

  onFileSelect(event: Event): void {
    const input = event.target as HTMLInputElement;
    if (input.files) {
      this.addFiles(Array.from(input.files));
      input.value = '';
    }
  }

  addFiles(files: File[]): void {
    const current = this.droppedFiles();
    this.droppedFiles.set([...current, ...files]);
    // Auto-detect pair type from files
    const detected = this.ingestion.detectPairType([...current, ...files]);
    if (detected === 'db_field_mapping') {
      this.pairType = 'db_field_mapping';
    }
  }

  removeFile(index: number): void {
    const files = [...this.droppedFiles()];
    files.splice(index, 1);
    this.droppedFiles.set(files);
  }

  async processFiles(): Promise<void> {
    const files = this.droppedFiles();
    if (files.length === 0) return;
    await this.ingestion.processFiles(
      files,
      this.pairType,
      this.sourceLang,
      this.targetLang,
      this.trustLevel,
    );
  }

  // ---------------------------------------------------------------------------
  // Review table handlers
  // ---------------------------------------------------------------------------

  toggleTermSelection(index: number): void {
    if (index < 0) return;
    const set = new Set(this.selectedTermIndices());
    if (set.has(index)) set.delete(index);
    else set.add(index);
    this.selectedTermIndices.set(set);
  }

  toggleAllTerms(): void {
    const terms = this.filteredTerms();
    const set = this.selectedTermIndices();
    const visibleIndices = terms
      .map((term) => this.termIndex(term))
      .filter((index): index is number => index >= 0);
    const allSelected =
      visibleIndices.length > 0 &&
      visibleIndices.every((index) => set.has(index));

    if (allSelected) {
      this.selectedTermIndices.set(new Set());
    } else {
      this.selectedTermIndices.set(new Set(visibleIndices));
    }
  }

  toggleParagraphSelection(index: number): void {
    if (index < 0) return;
    const set = new Set(this.selectedParagraphIndices());
    if (set.has(index)) set.delete(index);
    else set.add(index);
    this.selectedParagraphIndices.set(set);
  }

  toggleAllParagraphs(): void {
    const paragraphs = this.filteredParagraphs();
    const set = this.selectedParagraphIndices();
    const visibleIndices = paragraphs
      .map((paragraph) => this.paragraphIndex(paragraph))
      .filter((index): index is number => index >= 0);
    const allSelected =
      visibleIndices.length > 0 &&
      visibleIndices.every((index) => set.has(index));

    if (allSelected) {
      this.selectedParagraphIndices.set(new Set());
    } else {
      this.selectedParagraphIndices.set(new Set(visibleIndices));
    }
  }

  approveSelected(): void {
    if (this.activeTab() === 'terms') {
      this.ingestion.approveSelected([...this.selectedTermIndices()], 'term');
      this.selectedTermIndices.set(new Set());
    } else {
      this.ingestion.approveSelected([...this.selectedParagraphIndices()], 'paragraph');
      this.selectedParagraphIndices.set(new Set());
    }
  }

  rejectSelected(): void {
    if (this.activeTab() === 'terms') {
      this.ingestion.rejectSelected([...this.selectedTermIndices()], 'term');
      this.selectedTermIndices.set(new Set());
    } else {
      this.ingestion.rejectSelected([...this.selectedParagraphIndices()], 'paragraph');
      this.selectedParagraphIndices.set(new Set());
    }
  }

  approveAllPending(): void {
    this.ingestion.approveAllPending();
  }

  approveTerm(index: number): void {
    if (index < 0) return;
    this.ingestion.updateTermStatus(index, 'approved');
  }

  rejectTerm(index: number): void {
    if (index < 0) return;
    this.ingestion.updateTermStatus(index, 'rejected');
  }

  startEditTerm(index: number): void {
    const term = this.batch()?.termPairs[index];
    if (!term) return;
    this.editingTermIndex.set(index);
    this.editingTargetTerm.set(term.targetTerm);
  }

  saveEditTerm(): void {
    const index = this.editingTermIndex();
    if (index === null) return;

    const targetTerm = this.editingTargetTerm().trim();
    if (!targetTerm) {
      this.toast.error('Target term cannot be empty.');
      return;
    }

    this.ingestion.updateTermPair(index, { targetTerm });
    this.editingTermIndex.set(null);
    this.editingTargetTerm.set('');
  }

  cancelEditTerm(): void {
    this.editingTermIndex.set(null);
    this.editingTargetTerm.set('');
  }

  approveParagraph(index: number): void {
    if (index < 0) return;
    this.ingestion.updateParagraphStatus(index, 'approved');
  }

  rejectParagraph(index: number): void {
    if (index < 0) return;
    this.ingestion.updateParagraphStatus(index, 'rejected');
  }

  termIndex(term: TermPair): number {
    const batch = this.batch();
    return batch ? batch.termPairs.indexOf(term) : -1;
  }

  paragraphIndex(paragraph: ParagraphPair): number {
    const batch = this.batch();
    return batch ? batch.paragraphPairs.indexOf(paragraph) : -1;
  }

  trackTerm(_index: number, term: TermPair): string {
    return [
      term.sourceTerm,
      term.targetTerm,
      term.sourceLang,
      term.targetLang,
      term.category,
      term.confidence,
    ].join('|');
  }

  trackParagraph(_index: number, paragraph: ParagraphPair): string {
    return [
      paragraph.sourceText,
      paragraph.targetText,
      paragraph.sourceLang,
      paragraph.targetLang,
      paragraph.page ?? '',
      paragraph.confidence,
    ].join('|');
  }

  confidenceClass(confidence: number): string {
    if (confidence >= 0.9) return 'confidence-high';
    if (confidence >= 0.7) return 'confidence-medium';
    return 'confidence-low';
  }

  truncate(text: string, maxLen = 80): string {
    return text.length > maxLen ? text.substring(0, maxLen) + '…' : text;
  }

  // ---------------------------------------------------------------------------
  // Commit handlers
  // ---------------------------------------------------------------------------

  commitBatch(): void {
    if (this.activeMode() === 'chat') {
      this.store.setMode('training');
      this.toast.info('Training mode enabled. Review the batch and commit again when ready.');
      return;
    }

    if (this.activeMode() === 'cowork') {
      this.commitConfirmationOpen.set(true);
      return;
    }

    this.commitBatchNow();
  }

  commitBatchNow(): void {
    this.committing.set(true);
    this.ingestion
      .commit({
        toTm: this.commitToTm,
        toGlossary: this.commitToGlossary,
        toVectorStore: this.commitToVector,
      })
      .subscribe({
        next: (result) => {
          this.committing.set(false);
          const total = result.termsSaved + result.paragraphsSaved;
          this.toast.success(
            this.i18n.t('pairStudio.commitSuccess', { count: String(total) }),
          );
        },
        error: () => {
          this.committing.set(false);
          this.toast.error(this.i18n.t('pairStudio.commitFailed'));
        },
      });
  }

  switchToTrainingMode(): void {
    if (this.activeMode() !== 'training') {
      this.store.setMode('training');
      this.toast.info('Training mode enabled for live Pair Studio actions.');
    }
  }

  discardBatch(): void {
    this.ingestion.discardBatch();
    this.droppedFiles.set([]);
    this.selectedTermIndices.set(new Set());
    this.selectedParagraphIndices.set(new Set());
    this.cancelEditTerm();
  }

  startNewBatch(): void {
    this.discardBatch();
  }
}
