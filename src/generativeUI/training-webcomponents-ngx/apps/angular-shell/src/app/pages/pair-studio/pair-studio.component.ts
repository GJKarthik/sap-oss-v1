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

@Component({
  selector: 'app-pair-studio',
  standalone: true,
  imports: [CommonModule, FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './pair-studio.component.html',
  styleUrls: ['./pair-studio.component.scss'],
})
export class PairStudioComponent {
  readonly i18n = inject(I18nService);
  readonly ingestion = inject(IngestionService);
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

  // ---------------------------------------------------------------------------
  // Computed
  // ---------------------------------------------------------------------------

  readonly batch = this.ingestion.currentBatch;
  readonly processing = this.ingestion.processing;
  readonly progress = this.ingestion.progress;
  readonly progressLabel = this.ingestion.progressLabel;
  readonly commitResult = this.ingestion.lastCommitResult;

  readonly canProcess = computed(() => this.droppedFiles().length > 0 && !this.processing());

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
    const set = new Set(this.selectedTermIndices());
    if (set.has(index)) set.delete(index);
    else set.add(index);
    this.selectedTermIndices.set(set);
  }

  toggleAllTerms(): void {
    const terms = this.filteredTerms();
    const set = this.selectedTermIndices();
    if (set.size === terms.length) {
      this.selectedTermIndices.set(new Set());
    } else {
      this.selectedTermIndices.set(new Set(terms.map((_, i) => i)));
    }
  }

  toggleParagraphSelection(index: number): void {
    const set = new Set(this.selectedParagraphIndices());
    if (set.has(index)) set.delete(index);
    else set.add(index);
    this.selectedParagraphIndices.set(set);
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
    this.ingestion.updateTermStatus(index, 'approved');
  }

  rejectTerm(index: number): void {
    this.ingestion.updateTermStatus(index, 'rejected');
  }

  startEditTerm(index: number): void {
    this.editingTermIndex.set(index);
  }

  saveEditTerm(index: number, updates: Partial<TermPair>): void {
    this.ingestion.updateTermPair(index, updates);
    this.editingTermIndex.set(null);
  }

  cancelEditTerm(): void {
    this.editingTermIndex.set(null);
  }

  approveParagraph(index: number): void {
    this.ingestion.updateParagraphStatus(index, 'approved');
  }

  rejectParagraph(index: number): void {
    this.ingestion.updateParagraphStatus(index, 'rejected');
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

  discardBatch(): void {
    this.ingestion.discardBatch();
    this.droppedFiles.set([]);
    this.selectedTermIndices.set(new Set());
    this.selectedParagraphIndices.set(new Set());
  }

  startNewBatch(): void {
    this.discardBatch();
  }
}
