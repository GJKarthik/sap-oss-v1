/**
 * Shared Prompt Template Library — Training Console
 *
 * Team-curated prompt templates with categories, search, create/edit, and usage tracking.
 * Uses Angular 20 standalone + @if/@for control flow.
 */

import { Component, ChangeDetectionStrategy, inject, OnInit, OnDestroy, signal, computed } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { Subject, takeUntil } from 'rxjs';
import { environment } from '../../../environments/environment';
import { I18nService } from '../../services/i18n.service';
import { ToastService } from '../../services/toast.service';
import { Ui5TrainingComponentsModule } from '../../shared/ui5-training-components.module';
import '@ui5/webcomponents/dist/Tag.js';
import '@ui5/webcomponents/dist/Button.js';
import '@ui5/webcomponents/dist/Input.js';
import '@ui5/webcomponents/dist/TextArea.js';

interface PromptTemplate {
  id: string; name: string; content: string; category: string; description: string;
  tags: string[]; created_by: string; created_at: string; updated_at: string; usage_count: number; version: number;
}

@Component({
  selector: 'app-prompt-library',
  standalone: true,
  imports: [CommonModule, Ui5TrainingComponentsModule, FormsModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="prompt-page">
      <ui5-breadcrumbs>
        <ui5-breadcrumbs-item href="/dashboard" text="Home"></ui5-breadcrumbs-item>
        <ui5-breadcrumbs-item text="Prompt Library"></ui5-breadcrumbs-item>
      </ui5-breadcrumbs>
      <header class="page-header">
        <h2>{{ i18n.t('promptLibrary.title') }}</h2>
        <div class="header-actions">
          <ui5-input [placeholder]="i18n.t('promptLibrary.searchPlaceholder')" [value]="searchQuery()" (input)="searchQuery.set($any($event.target).value)" style="min-width: 200px;"></ui5-input>
          <ui5-button design="Emphasized" icon="add" (click)="showCreate.set(!showCreate())">{{ showCreate() ? i18n.t('common.cancel') : i18n.t('promptLibrary.newPrompt') }}</ui5-button>
        </div>
      </header>

      @if (loading()) {
        <div style="display: flex; justify-content: center; padding: 2rem;" role="status" aria-live="polite">
          <ui5-busy-indicator active size="M"></ui5-busy-indicator>
        </div>
      }

      <!-- Stats bar -->
      <div class="stats-bar">
        <div class="stat"><span class="stat-value">{{ prompts().length }}</span><span class="stat-label">{{ i18n.t('promptLibrary.templates') }}</span></div>
        <div class="stat"><span class="stat-value">{{ totalUsage() }}</span><span class="stat-label">{{ i18n.t('promptLibrary.totalUses') }}</span></div>
        <div class="stat"><span class="stat-value">{{ categories().length }}</span><span class="stat-label">{{ i18n.t('promptLibrary.categories') }}</span></div>
      </div>

      <!-- Category filter -->
      <div class="category-bar">
        @for (cat of categories(); track cat) {
          <ui5-button [attr.design]="selectedCategory() === cat ? 'Emphasized' : 'Default'" (click)="selectedCategory.set(cat)">{{ cat }}</ui5-button>
        }
        @if (selectedCategory()) {
          <ui5-button design="Transparent" (click)="selectedCategory.set(null); loadPrompts()">{{ i18n.t('promptLibrary.clear') }}</ui5-button>
        }
      </div>

      <!-- Create form -->
      @if (showCreate()) {
        <div class="create-form">
          <h3>{{ i18n.t('promptLibrary.newPromptTemplate') }}</h3>
          <ui5-input ngDefaultControl [(ngModel)]="draftName" name="name" [placeholder]="i18n.t('promptLibrary.promptName')" style="width: 100%;"></ui5-input>
          <ui5-input ngDefaultControl [(ngModel)]="draftCategory" name="category" [placeholder]="i18n.t('promptLibrary.category')" style="width: 100%;"></ui5-input>
          <ui5-input ngDefaultControl [(ngModel)]="draftDescription" name="desc" [placeholder]="i18n.t('promptLibrary.description')" style="width: 100%;"></ui5-input>
          <ui5-textarea ngDefaultControl [(ngModel)]="draftContent" name="content" [placeholder]="i18n.t('promptLibrary.promptContent')" [rows]="5" growing style="width: 100%;"></ui5-textarea>
          <ui5-input ngDefaultControl [(ngModel)]="draftTags" name="tags" [placeholder]="i18n.t('promptLibrary.tagsPlaceholder')" style="width: 100%;"></ui5-input>
          <div class="form-actions">
            <ui5-button design="Emphasized" (click)="createPrompt()">{{ i18n.t('common.create') }}</ui5-button>
            <ui5-button design="Transparent" (click)="showCreate.set(false)">{{ i18n.t('common.cancel') }}</ui5-button>
          </div>
        </div>
      }

      <div class="main-layout">
        <!-- Prompt grid -->
        <div class="prompt-grid">
          @for (p of filtered(); track p.id) {
            <div class="prompt-card" [class.selected]="previewId() === p.id" (click)="selectForPreview(p)">
              <div class="card-header">
                <strong>{{ p.name }}</strong>
                <ui5-tag design="Information">{{ p.category }}</ui5-tag>
              </div>
              <p class="desc">{{ p.description || i18n.t('promptLibrary.noDescription') }}</p>
              <pre class="content-preview">{{ p.content }}</pre>
              <div class="tag-row">
                @for (tag of p.tags; track tag) { <ui5-tag>{{ tag }}</ui5-tag> }
              </div>
              <div class="meta-row">
                <span class="version-badge">v{{ p.version }}</span>
                <span class="usage-badge">{{ p.usage_count }} {{ i18n.t('promptLibrary.uses') }}</span>
                <span>{{ i18n.t('promptLibrary.by') }} {{ p.created_by }}</span>
              </div>
              <div class="action-row">
                <ui5-button design="Default" icon="copy" (click)="copy(p); $event.stopPropagation()">{{ i18n.t('promptLibrary.copy') }}</ui5-button>
                <ui5-button design="Positive" icon="accept" (click)="use(p); $event.stopPropagation()">{{ i18n.t('promptLibrary.use') }}</ui5-button>
                <ui5-button design="Negative" icon="delete" (click)="remove(p); $event.stopPropagation()">{{ i18n.t('common.delete') }}</ui5-button>
              </div>
            </div>
          }
        </div>

        <!-- Preview panel -->
        @if (previewPrompt()) {
          <div class="preview-panel">
            <h4>{{ previewPrompt()!.name }}</h4>
            <div class="preview-meta">
              <div class="pm-item"><span class="pm-label">{{ i18n.t('promptLibrary.version') }}</span><ui5-tag design="Information">v{{ previewPrompt()!.version }}</ui5-tag></div>
              <div class="pm-item"><span class="pm-label">{{ i18n.t('promptLibrary.uses') }}</span><ui5-tag design="Positive">{{ previewPrompt()!.usage_count }}</ui5-tag></div>
              <div class="pm-item"><span class="pm-label">{{ i18n.t('promptLibrary.category') }}</span><ui5-tag>{{ previewPrompt()!.category }}</ui5-tag></div>
              <div class="pm-item"><span class="pm-label">{{ i18n.t('promptLibrary.author') }}</span><span>{{ previewPrompt()!.created_by }}</span></div>
            </div>
            <h5>{{ i18n.t('promptLibrary.templateContent') }}</h5>
            <pre class="preview-content">{{ previewPrompt()!.content }}</pre>
            @if (templateVars().length) {
              <h5>{{ i18n.t('promptLibrary.testVariables') }}</h5>
              @for (v of templateVars(); track v) {
                <div class="var-input">
                  <label>{{ v }}</label>
                  <ui5-input ngDefaultControl [(ngModel)]="testValues[v]" [placeholder]="'Enter ' + v + '...'" style="width: 100%;"></ui5-input>
                </div>
              }
              <ui5-button design="Emphasized" icon="play" (click)="renderPreview()">{{ i18n.t('promptLibrary.renderPreview') }}</ui5-button>
            }
            @if (renderedPreview()) {
              <h5>{{ i18n.t('promptLibrary.renderedOutput') }}</h5>
              <pre class="rendered-content">{{ renderedPreview() }}</pre>
              <ui5-button design="Default" icon="copy" (click)="copyRendered()">{{ i18n.t('promptLibrary.copyRendered') }}</ui5-button>
            }
            <ui5-button design="Transparent" icon="decline" (click)="previewId.set(null)">{{ i18n.t('common.close') }}</ui5-button>
          </div>
        }
      </div>

      @if (filtered().length === 0 && !loading()) {
        <div class="empty-state">
          <p>{{ i18n.t('promptLibrary.emptyState') }}</p>
        </div>
      }
    </div>
  `,
  styles: [`
    .prompt-page { padding: 1.5rem; max-width: 1400px; margin: 0 auto; }
    .page-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; flex-wrap: wrap; gap: 0.5rem; }
    .page-header h2 { margin: 0; }
    .header-actions { display: flex; gap: 0.5rem; }
    .stats-bar { display: flex; gap: 2rem; padding: 0.75rem 1rem; background: var(--sapShell_Background, #f5f6f7); border-radius: 0.5rem; margin-bottom: 1rem; }
    .stat { display: flex; flex-direction: column; align-items: center; }
    .stat-value { font-size: 1.25rem; font-weight: 700; }
    .stat-label { font-size: 0.75rem; color: var(--sapContent_LabelColor); }
    .category-bar { display: flex; gap: 0.5rem; flex-wrap: wrap; margin-bottom: 1rem; }
    .create-form { border: 1px solid var(--sapTile_BorderColor); border-radius: 0.5rem; padding: 1rem; margin-bottom: 1rem; display: grid; gap: 0.75rem; max-width: 600px; }
    .form-actions { display: flex; gap: 0.5rem; }
    .main-layout { display: flex; gap: 1rem; align-items: flex-start; }
    .prompt-grid { flex: 1; display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; }
    .prompt-card { border: 1px solid var(--sapTile_BorderColor); border-radius: 0.5rem; padding: 1rem; cursor: pointer; transition: box-shadow 0.15s; }
    .prompt-card:hover { box-shadow: 0 2px 8px rgba(0,0,0,0.12); }
    .prompt-card.selected { outline: 2px solid var(--sapSelectedColor, #0854a0); }
    .card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.5rem; }
    .desc { font-size: 0.875rem; margin: 0 0 0.5rem; }
    .content-preview { background: var(--sapShell_Background, #f5f6f7); padding: 0.5rem; border-radius: 0.25rem; font-size: 0.75rem; max-height: 100px; overflow: auto; white-space: pre-wrap; margin: 0 0 0.5rem; }
    .tag-row { display: flex; gap: 0.25rem; flex-wrap: wrap; margin-bottom: 0.5rem; }
    .meta-row { display: flex; gap: 0.75rem; font-size: 0.75rem; color: var(--sapContent_LabelColor); margin-bottom: 0.5rem; align-items: center; }
    .version-badge { background: var(--sapInformationBackground, #e5f0fa); color: var(--sapInformativeColor, #0a6ed1); padding: 0.1rem 0.4rem; border-radius: 0.25rem; font-weight: 600; }
    .usage-badge { font-weight: 600; }
    .action-row { display: flex; gap: 0.5rem; }
    .preview-panel { width: 360px; min-width: 300px; border: 1px solid var(--sapTile_BorderColor); border-radius: 0.5rem; padding: 1rem; display: flex; flex-direction: column; gap: 0.75rem; position: sticky; top: 1rem; }
    .preview-panel h4 { margin: 0; }
    .preview-panel h5 { margin: 0; font-size: 0.875rem; }
    .preview-meta { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }
    .pm-item { display: flex; flex-direction: column; gap: 0.25rem; }
    .pm-label { font-size: 0.75rem; color: var(--sapContent_LabelColor); font-weight: 600; }
    .preview-content { background: var(--sapShell_Background, #f5f6f7); padding: 0.75rem; border-radius: 0.25rem; font-size: 0.75rem; max-height: 200px; overflow: auto; white-space: pre-wrap; margin: 0; }
    .var-input { display: flex; flex-direction: column; gap: 0.25rem; }
    .var-input label { font-size: 0.75rem; font-weight: 600; color: var(--sapContent_LabelColor); }
    .rendered-content { background: var(--sapPositiveBackground, #f1fdf5); padding: 0.75rem; border-radius: 0.25rem; font-size: 0.75rem; max-height: 200px; overflow: auto; white-space: pre-wrap; margin: 0; border: 1px solid var(--sapPositiveBorderColor, #36a41d); }
    .empty-state { text-align: center; padding: 3rem; color: var(--sapContent_LabelColor); }
    @media (max-width: 960px) { .main-layout { flex-direction: column; } .preview-panel { width: 100%; position: static; } }
  `]
})
export class PromptLibraryComponent implements OnInit, OnDestroy {
  private readonly http = inject(HttpClient);
  readonly i18n = inject(I18nService);
  private readonly toast = inject(ToastService);
  private readonly destroy$ = new Subject<void>();
  private readonly apiUrl = `${environment.apiBaseUrl}/prompts`;

  readonly prompts = signal<PromptTemplate[]>([]);
  readonly categories = signal<string[]>([]);
  readonly selectedCategory = signal<string | null>(null);
  readonly searchQuery = signal('');
  readonly showCreate = signal(false);
  readonly loading = signal(false);
  readonly previewId = signal<string | null>(null);
  readonly renderedPreview = signal('');

  draftName = ''; draftContent = ''; draftCategory = 'general'; draftDescription = ''; draftTags = '';
  testValues: Record<string, string> = {};

  readonly totalUsage = computed(() => this.prompts().reduce((s, p) => s + p.usage_count, 0));

  readonly filtered = computed(() => {
    let list = this.prompts();
    const cat = this.selectedCategory();
    if (cat) list = list.filter(p => p.category === cat);
    const q = this.searchQuery().toLowerCase().trim();
    if (q) list = list.filter(p => p.name.toLowerCase().includes(q) || p.description.toLowerCase().includes(q) || p.tags.some(t => t.includes(q)));
    return list;
  });

  readonly previewPrompt = computed(() => {
    const id = this.previewId();
    return id ? this.prompts().find(p => p.id === id) ?? null : null;
  });

  readonly templateVars = computed(() => {
    const p = this.previewPrompt();
    if (!p) return [];
    const matches = p.content.match(/\{\{(\w+)\}\}/g) || [];
    return [...new Set(matches.map(m => m.replace(/\{|\}/g, '')))];
  });

  ngOnInit(): void { this.loadPrompts(); this.loadCategories(); }
  ngOnDestroy(): void { this.destroy$.next(); this.destroy$.complete(); }

  loadPrompts(): void {
    this.loading.set(true);
    this.http.get<{ prompts: PromptTemplate[] }>(this.apiUrl).pipe(takeUntil(this.destroy$))
      .subscribe({ next: r => { this.prompts.set(r.prompts); this.loading.set(false); }, error: () => { this.toast.error(this.i18n.t('promptLibrary.loadFailed')); this.loading.set(false); } });
  }

  loadCategories(): void {
    this.http.get<{ categories: string[] }>(`${this.apiUrl}/categories`).pipe(takeUntil(this.destroy$))
      .subscribe({ next: r => this.categories.set(r.categories), error: () => this.toast.error(this.i18n.t('promptLibrary.loadCategoriesFailed')) });
  }

  createPrompt(): void {
    const body = { name: this.draftName.trim(), content: this.draftContent.trim(), category: this.draftCategory.trim() || 'general', description: this.draftDescription.trim(), tags: this.draftTags.split(',').map(t => t.trim()).filter(Boolean) };
    this.http.post(this.apiUrl, body).pipe(takeUntil(this.destroy$))
      .subscribe({ next: () => { this.showCreate.set(false); this.draftName = ''; this.draftContent = ''; this.draftCategory = 'general'; this.draftDescription = ''; this.draftTags = ''; this.loadPrompts(); this.loadCategories(); }, error: () => this.toast.error(this.i18n.t('promptLibrary.createFailed')) });
  }

  selectForPreview(p: PromptTemplate): void { this.previewId.set(p.id); this.testValues = {}; this.renderedPreview.set(''); }

  renderPreview(): void {
    const p = this.previewPrompt();
    if (!p) return;
    let rendered = p.content;
    for (const [key, val] of Object.entries(this.testValues)) {
      rendered = rendered.replace(new RegExp(`\\{\\{${key}\\}\\}`, 'g'), val || `[${key}]`);
    }
    this.renderedPreview.set(rendered);
  }

  use(p: PromptTemplate): void { this.http.post(`${this.apiUrl}/${p.id}/use`, {}).pipe(takeUntil(this.destroy$)).subscribe(); navigator.clipboard?.writeText(p.content); }
  copy(p: PromptTemplate): void { navigator.clipboard?.writeText(p.content); }
  copyRendered(): void { navigator.clipboard?.writeText(this.renderedPreview()); }
  remove(p: PromptTemplate): void { if (this.previewId() === p.id) this.previewId.set(null); this.http.delete(`${this.apiUrl}/${p.id}`).pipe(takeUntil(this.destroy$)).subscribe({ next: () => this.loadPrompts(), error: () => this.toast.error(this.i18n.t('promptLibrary.deleteFailed')) }); }
}