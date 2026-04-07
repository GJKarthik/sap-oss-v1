/**
 * Shared Prompt Template Library Page — AI Fabric Console
 *
 * Team-curated prompt templates with categories, search, create/edit, and usage tracking.
 */

import { Component, DestroyRef, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { Ui5WebcomponentsModule } from '@ui5/webcomponents-ngx';
import { environment } from '../../../environments/environment';
import { EmptyStateComponent, DateFormatPipe } from '../../shared';
import { TranslatePipe, I18nService } from '../../shared/services/i18n.service';

interface PromptTemplate {
  id: string;
  name: string;
  content: string;
  category: string;
  description: string;
  tags: string[];
  created_by: string;
  created_at: string;
  updated_at: string;
  usage_count: number;
  version: number;
}

@Component({
  selector: 'app-prompt-library',
  standalone: true,
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, EmptyStateComponent, DateFormatPipe, TranslatePipe],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">{{ 'promptLibrary.title' | translate }}</ui5-title>
        <ui5-input slot="endContent" [attr.placeholder]="i18n.t('promptLibrary.searchPlaceholder')" [value]="searchQuery" (input)="onSearch($event)" style="min-width: 200px;"></ui5-input>
        <ui5-button slot="endContent" design="Emphasized" icon="add" (click)="showCreateForm = !showCreateForm">
          {{ showCreateForm ? ('common.cancel' | translate) : ('promptLibrary.newPrompt' | translate) }}
        </ui5-button>
      </ui5-bar>

      <div class="library-content">
        <!-- Stats bar -->
        <div class="stats-bar">
          <div class="stat"><span class="stat-value">{{ prompts.length }}</span><span class="stat-label">{{ 'promptLibrary.templates' | translate }}</span></div>
          <div class="stat"><span class="stat-value">{{ totalUsageCount }}</span><span class="stat-label">{{ 'promptLibrary.totalUses' | translate }}</span></div>
          <div class="stat"><span class="stat-value">{{ categories.length }}</span><span class="stat-label">{{ 'promptLibrary.categories' | translate }}</span></div>
        </div>

        <!-- Category filter -->
        <div class="category-bar">
          <ui5-button *ngFor="let cat of categories" [design]="selectedCategory === cat ? 'Emphasized' : 'Default'" (click)="filterByCategory(cat)">{{ cat }}</ui5-button>
          <ui5-button *ngIf="selectedCategory" design="Transparent" (click)="filterByCategory(null)">{{ 'promptLibrary.clearFilter' | translate }}</ui5-button>
        </div>

        <!-- Create form -->
        <ui5-card *ngIf="showCreateForm" class="create-card">
          <ui5-card-header slot="header" [attr.title-text]="i18n.t('promptLibrary.newPromptTemplate')"></ui5-card-header>
          <div class="form-grid">
            <ui5-input ngDefaultControl [(ngModel)]="draft.name" name="name" [attr.placeholder]="i18n.t('promptLibrary.promptNamePlaceholder')" required></ui5-input>
            <ui5-input ngDefaultControl [(ngModel)]="draft.category" name="category" [attr.placeholder]="i18n.t('promptLibrary.categoryPlaceholder')"></ui5-input>
            <ui5-input ngDefaultControl [(ngModel)]="draft.description" name="description" [attr.placeholder]="i18n.t('promptLibrary.descriptionPlaceholder')"></ui5-input>
            <ui5-textarea ngDefaultControl [(ngModel)]="draft.content" name="content" [placeholder]="'Prompt content (use {'+'{variable}'+'}  for placeholders)'" [rows]="5" growing></ui5-textarea>
            <ui5-input ngDefaultControl [(ngModel)]="draft.tagsStr" name="tags" [attr.placeholder]="i18n.t('promptLibrary.tagsPlaceholder')"></ui5-input>
            <div class="form-actions">
              <ui5-button design="Emphasized" (click)="createPrompt()" [disabled]="!draft.name.trim() || !draft.content.trim()">{{ 'common.create' | translate }}</ui5-button>
              <ui5-button design="Transparent" (click)="showCreateForm = false">{{ 'common.cancel' | translate }}</ui5-button>
            </div>
          </div>
        </ui5-card>

        <div class="main-layout">
          <!-- Prompt cards -->
          <div class="prompt-grid">
            <ui5-card *ngFor="let prompt of filteredPrompts; trackBy: trackById" class="prompt-card" [class.selected]="previewPrompt?.id === prompt.id" (click)="selectForPreview(prompt)">
              <ui5-card-header slot="header" [titleText]="prompt.name" [subtitleText]="prompt.category">
              </ui5-card-header>
              <div class="prompt-body">
                <p class="prompt-desc">{{ prompt.description || ('promptLibrary.noDescription' | translate) }}</p>
                <pre class="prompt-content">{{ prompt.content }}</pre>
                <div class="prompt-tags">
                  <ui5-tag *ngFor="let tag of prompt.tags" design="Information">{{ tag }}</ui5-tag>
                </div>
                <div class="prompt-meta">
                  <span class="version-badge">v{{ prompt.version }}</span>
                  <span class="usage-badge">{{ prompt.usage_count }} {{ 'promptLibrary.uses' | translate }}</span>
                  <span>by {{ prompt.created_by }}</span>
                  <span>{{ prompt.updated_at | dateFormat:'short' }}</span>
                </div>
                <div class="prompt-actions">
                  <ui5-button design="Default" icon="copy" (click)="copyPrompt(prompt); $event.stopPropagation()">{{ 'common.copy' | translate }}</ui5-button>
                  <ui5-button design="Positive" icon="accept" (click)="usePrompt(prompt); $event.stopPropagation()">{{ 'common.use' | translate }}</ui5-button>
                  <ui5-button design="Negative" icon="delete" (click)="deletePrompt(prompt); $event.stopPropagation()">{{ 'common.delete' | translate }}</ui5-button>
                </div>
              </div>
            </ui5-card>
          </div>

          <!-- Preview / Test panel -->
          <div class="preview-panel" *ngIf="previewPrompt">
            <ui5-card>
              <ui5-card-header slot="header" [titleText]="previewPrompt.name" [attr.subtitle-text]="i18n.t('promptLibrary.previewAndTest')">
              </ui5-card-header>
              <div class="preview-body">
                <div class="preview-meta-grid">
                  <div class="pm-item"><span class="pm-label">{{ 'promptLibrary.version' | translate }}</span><ui5-tag design="Information">v{{ previewPrompt.version }}</ui5-tag></div>
                  <div class="pm-item"><span class="pm-label">{{ 'promptLibrary.category' | translate }}</span><ui5-tag>{{ previewPrompt.category }}</ui5-tag></div>
                  <div class="pm-item"><span class="pm-label">{{ 'promptLibrary.usesLabel' | translate }}</span><ui5-tag design="Positive">{{ previewPrompt.usage_count }}</ui5-tag></div>
                  <div class="pm-item"><span class="pm-label">{{ 'promptLibrary.author' | translate }}</span><span>{{ previewPrompt.created_by }}</span></div>
                </div>
                <h5 class="section-title">{{ 'promptLibrary.templateContent' | translate }}</h5>
                <pre class="preview-content">{{ previewPrompt.content }}</pre>
                <div *ngIf="templateVars.length" class="test-section">
                  <h5 class="section-title">{{ 'promptLibrary.testVariables' | translate }}</h5>
                  <div *ngFor="let v of templateVars" class="var-input">
                    <label>{{ v }}</label>
                    <ui5-input ngDefaultControl [(ngModel)]="testVarValues[v]" [placeholder]="'Enter ' + v + '...'" style="width: 100%;"></ui5-input>
                  </div>
                  <ui5-button design="Emphasized" icon="play" (click)="renderPreview()">{{ 'promptLibrary.renderPreview' | translate }}</ui5-button>
                </div>
                <div *ngIf="renderedPreview" class="rendered-section">
                  <h5 class="section-title">{{ 'promptLibrary.renderedOutput' | translate }}</h5>
                  <pre class="rendered-content">{{ renderedPreview }}</pre>
                  <ui5-button design="Default" icon="copy" (click)="copyRendered()">{{ 'promptLibrary.copyRendered' | translate }}</ui5-button>
                </div>
                <ui5-button design="Transparent" icon="decline" (click)="previewPrompt = null; renderedPreview = ''">{{ 'promptLibrary.closePreview' | translate }}</ui5-button>
              </div>
            </ui5-card>
          </div>
        </div>

        <app-empty-state *ngIf="filteredPrompts.length === 0 && !loading" icon="document" [title]="'promptLibrary.noPromptsFound' | translate" [description]="'promptLibrary.noPromptsDescription' | translate"></app-empty-state>
      </div>
    </ui5-page>
  `,

  styles: [`
    .library-content { padding: 1rem; max-width: 1400px; margin: 0 auto; display: flex; flex-direction: column; gap: 1rem; }
    .stats-bar { display: flex; gap: 2rem; padding: 0.75rem 1rem; background: var(--sapShell_Background, #f5f6f7); border-radius: 0.5rem; }
    .stat { display: flex; flex-direction: column; align-items: center; }
    .stat-value { font-size: 1.25rem; font-weight: 700; color: var(--sapContent_ForegroundColor); }
    .stat-label { font-size: 0.75rem; color: var(--sapContent_LabelColor); }
    .category-bar { display: flex; gap: 0.5rem; flex-wrap: wrap; }
    .create-card { max-width: 600px; }
    .form-grid { padding: 1rem; display: grid; gap: 0.75rem; }
    .form-actions { display: flex; gap: 0.5rem; }
    .main-layout { display: flex; gap: 1rem; align-items: flex-start; }
    .prompt-grid { flex: 1; display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem; }
    .prompt-card { cursor: pointer; transition: box-shadow 0.15s; }
    .prompt-card:hover { box-shadow: 0 2px 8px rgba(0,0,0,0.12); }
    .prompt-card.selected { outline: 2px solid var(--sapSelectedColor, #0854a0); }
    .prompt-body { padding: 0.75rem; }
    .prompt-desc { font-size: 0.875rem; margin: 0 0 0.5rem; }
    .prompt-content { background: var(--sapShell_Background, #f5f6f7); padding: 0.75rem; border-radius: 0.25rem; font-size: 0.75rem; max-height: 100px; overflow: auto; white-space: pre-wrap; margin: 0 0 0.5rem; }
    .prompt-tags { display: flex; gap: 0.25rem; flex-wrap: wrap; margin-bottom: 0.5rem; }
    .prompt-meta { display: flex; gap: 0.75rem; font-size: 0.75rem; color: var(--sapContent_LabelColor); margin-bottom: 0.5rem; align-items: center; flex-wrap: wrap; }
    .version-badge { background: var(--sapInformationBackground, #e5f0fa); color: var(--sapInformativeColor, #0a6ed1); padding: 0.1rem 0.4rem; border-radius: 0.25rem; font-weight: 600; }
    .usage-badge { font-weight: 600; }
    .prompt-actions { display: flex; gap: 0.5rem; }
    .preview-panel { width: 380px; min-width: 320px; position: sticky; top: 1rem; }
    .preview-body { padding: 1rem; display: flex; flex-direction: column; gap: 0.75rem; }
    .preview-meta-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }
    .pm-item { display: flex; flex-direction: column; gap: 0.25rem; }
    .pm-label { font-size: 0.75rem; color: var(--sapContent_LabelColor); font-weight: 600; }
    .section-title { margin: 0; font-size: 0.875rem; font-weight: 600; }
    .preview-content { background: var(--sapShell_Background, #f5f6f7); padding: 0.75rem; border-radius: 0.25rem; font-size: 0.75rem; max-height: 200px; overflow: auto; white-space: pre-wrap; margin: 0; }
    .test-section { display: flex; flex-direction: column; gap: 0.5rem; }
    .var-input { display: flex; flex-direction: column; gap: 0.25rem; }
    .var-input label { font-size: 0.75rem; font-weight: 600; color: var(--sapContent_LabelColor); }
    .rendered-section { display: flex; flex-direction: column; gap: 0.5rem; }
    .rendered-content { background: var(--sapPositiveBackground, #f1fdf5); padding: 0.75rem; border-radius: 0.25rem; font-size: 0.75rem; max-height: 200px; overflow: auto; white-space: pre-wrap; margin: 0; border: 1px solid var(--sapPositiveBorderColor, #36a41d); }
    @media (max-width: 960px) { .main-layout { flex-direction: column; } .preview-panel { width: 100%; position: static; } }
  `]
})
export class PromptLibraryComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly destroyRef = inject(DestroyRef);
  readonly i18n = inject(I18nService);
  private readonly apiUrl = `${environment.apiBaseUrl}/prompts`;

  prompts: PromptTemplate[] = [];
  filteredPrompts: PromptTemplate[] = [];
  categories: string[] = [];
  selectedCategory: string | null = null;
  searchQuery = '';
  loading = false;
  showCreateForm = false;
  draft = { name: '', content: '', category: 'general', description: '', tagsStr: '' };

  // Preview & test
  previewPrompt: PromptTemplate | null = null;
  templateVars: string[] = [];
  testVarValues: Record<string, string> = {};
  renderedPreview = '';

  get totalUsageCount(): number { return this.prompts.reduce((sum, p) => sum + p.usage_count, 0); }

  ngOnInit(): void { this.loadPrompts(); this.loadCategories(); }

  loadPrompts(): void {
    this.loading = true;
    const params: Record<string, string> = {};
    if (this.selectedCategory) params['category'] = this.selectedCategory;
    this.http.get<{ prompts: PromptTemplate[] }>(this.apiUrl, { params })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({ next: res => { this.prompts = res.prompts; this.applySearch(); this.loading = false; }, error: () => this.loading = false });
  }

  loadCategories(): void {
    this.http.get<{ categories: string[] }>(`${this.apiUrl}/categories`)
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({ next: res => this.categories = res.categories, error: () => {} });
  }

  filterByCategory(cat: string | null): void { this.selectedCategory = cat; this.loadPrompts(); }
  onSearch(event: Event): void { this.searchQuery = (event.target as any)?.value || ''; this.applySearch(); }

  private applySearch(): void {
    const q = this.searchQuery.toLowerCase().trim();
    this.filteredPrompts = q ? this.prompts.filter(p => p.name.toLowerCase().includes(q) || p.description.toLowerCase().includes(q) || p.tags.some(t => t.includes(q))) : [...this.prompts];
  }

  createPrompt(): void {
    const body = { name: this.draft.name.trim(), content: this.draft.content.trim(), category: this.draft.category.trim() || 'general', description: this.draft.description.trim(), tags: this.draft.tagsStr.split(',').map(t => t.trim()).filter(Boolean) };
    this.http.post<PromptTemplate>(this.apiUrl, body).pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({ next: () => { this.showCreateForm = false; this.draft = { name: '', content: '', category: 'general', description: '', tagsStr: '' }; this.loadPrompts(); this.loadCategories(); } });
  }

  usePrompt(p: PromptTemplate): void { this.http.post(`${this.apiUrl}/${p.id}/use`, {}).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({ next: () => { p.usage_count++; } }); navigator.clipboard?.writeText(p.content); }
  copyPrompt(p: PromptTemplate): void { navigator.clipboard?.writeText(p.content); }
  deletePrompt(p: PromptTemplate): void { this.http.delete(`${this.apiUrl}/${p.id}`).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({ next: () => { if (this.previewPrompt?.id === p.id) this.previewPrompt = null; this.loadPrompts(); } }); }
  copyRendered(): void { navigator.clipboard?.writeText(this.renderedPreview); }
  trackById(_: number, item: PromptTemplate): string { return item.id; }

  selectForPreview(p: PromptTemplate): void { this.previewPrompt = p; this.extractVars(); }

  private extractVars(): void {
    if (!this.previewPrompt) { this.templateVars = []; this.testVarValues = {}; this.renderedPreview = ''; return; }
    const matches = this.previewPrompt.content.match(/\{\{(\w+)\}\}/g) || [];
    this.templateVars = [...new Set(matches.map(m => m.replace(/\{|\}/g, '')))];
    const prev = { ...this.testVarValues };
    this.testVarValues = {};
    this.templateVars.forEach(v => this.testVarValues[v] = prev[v] || '');
    this.renderedPreview = '';
  }

  renderPreview(): void {
    if (!this.previewPrompt) return;
    let rendered = this.previewPrompt.content;
    for (const [key, val] of Object.entries(this.testVarValues)) {
      rendered = rendered.replace(new RegExp(`\\{\\{${key}\\}\\}`, 'g'), val || `[${key}]`);
    }
    this.renderedPreview = rendered;
  }
}
