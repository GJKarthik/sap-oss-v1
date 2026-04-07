/**
 * Shared Prompt Template Library — Training Console
 *
 * Team-curated prompt templates with categories, search, create/edit, and usage tracking.
 * Uses Angular 20 standalone + @if/@for control flow.
 */

import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, inject, OnInit, OnDestroy, signal, computed } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { Subject, takeUntil } from 'rxjs';
import { environment } from '../../../environments/environment';
import { I18nService } from '../../services/i18n.service';
import '@ui5/webcomponents/dist/Card.js';
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
  imports: [FormsModule],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="prompt-page">
      <header class="page-header">
        <h2>Prompt Library</h2>
        <div class="header-actions">
          <ui5-input placeholder="Search prompts..." [value]="searchQuery()" (input)="searchQuery.set($any($event.target).value)" style="min-width: 200px;"></ui5-input>
          <ui5-button design="Emphasized" icon="add" (click)="showCreate.set(!showCreate())">{{ showCreate() ? 'Cancel' : 'New Prompt' }}</ui5-button>
        </div>
      </header>

      <!-- Category filter -->
      <div class="category-bar">
        @for (cat of categories(); track cat) {
          <ui5-button [attr.design]="selectedCategory() === cat ? 'Emphasized' : 'Default'" (click)="selectedCategory.set(cat)">{{ cat }}</ui5-button>
        }
        @if (selectedCategory()) {
          <ui5-button design="Transparent" (click)="selectedCategory.set(null); loadPrompts()">Clear</ui5-button>
        }
      </div>

      <!-- Create form -->
      @if (showCreate()) {
        <div class="create-form">
          <h3>New Prompt Template</h3>
          <ui5-input ngDefaultControl [(ngModel)]="draftName" name="name" placeholder="Prompt name" style="width: 100%;"></ui5-input>
          <ui5-input ngDefaultControl [(ngModel)]="draftCategory" name="category" placeholder="Category" style="width: 100%;"></ui5-input>
          <ui5-input ngDefaultControl [(ngModel)]="draftDescription" name="desc" placeholder="Description" style="width: 100%;"></ui5-input>
          <ui5-textarea ngDefaultControl [(ngModel)]="draftContent" name="content" placeholder="Prompt content..." [rows]="5" growing style="width: 100%;"></ui5-textarea>
          <ui5-input ngDefaultControl [(ngModel)]="draftTags" name="tags" placeholder="Tags (comma-separated)" style="width: 100%;"></ui5-input>
          <div class="form-actions">
            <ui5-button design="Emphasized" (click)="createPrompt()">Create</ui5-button>
            <ui5-button design="Transparent" (click)="showCreate.set(false)">Cancel</ui5-button>
          </div>
        </div>
      }

      <!-- Prompt grid -->
      <div class="prompt-grid">
        @for (p of filtered(); track p.id) {
          <div class="prompt-card">
            <div class="card-header">
              <strong>{{ p.name }}</strong>
              <ui5-tag design="Information">{{ p.category }}</ui5-tag>
            </div>
            <p class="desc">{{ p.description || 'No description' }}</p>
            <pre class="content-preview">{{ p.content }}</pre>
            <div class="tag-row">
              @for (tag of p.tags; track tag) { <ui5-tag>{{ tag }}</ui5-tag> }
            </div>
            <div class="meta-row">
              <span>v{{ p.version }} · {{ p.usage_count }} uses · by {{ p.created_by }}</span>
            </div>
            <div class="action-row">
              <ui5-button design="Default" icon="copy" (click)="copy(p)">Copy</ui5-button>
              <ui5-button design="Positive" icon="accept" (click)="use(p)">Use</ui5-button>
              <ui5-button design="Negative" icon="delete" (click)="remove(p)">Delete</ui5-button>
            </div>
          </div>
        }
      </div>

      @if (filtered().length === 0 && !loading()) {
        <div class="empty-state">
          <p>No prompts found. Create your first shared prompt template for the team.</p>
        </div>
      }
    </div>
  `,
  styles: [`
    .prompt-page { padding: 1.5rem; max-width: 1200px; margin: 0 auto; }
    .page-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; flex-wrap: wrap; gap: 0.5rem; }
    .page-header h2 { margin: 0; }
    .header-actions { display: flex; gap: 0.5rem; }
    .category-bar { display: flex; gap: 0.5rem; flex-wrap: wrap; margin-bottom: 1rem; }
    .create-form { border: 1px solid var(--sapTile_BorderColor); border-radius: 0.5rem; padding: 1rem; margin-bottom: 1rem; display: grid; gap: 0.75rem; max-width: 600px; }
    .form-actions { display: flex; gap: 0.5rem; }
    .prompt-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 1rem; }
    .prompt-card { border: 1px solid var(--sapTile_BorderColor); border-radius: 0.5rem; padding: 1rem; }
    .card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.5rem; }
    .desc { font-size: 0.875rem; margin: 0 0 0.5rem; }
    .content-preview { background: var(--sapShell_Background, #f5f6f7); padding: 0.5rem; border-radius: 0.25rem; font-size: 0.75rem; max-height: 100px; overflow: auto; white-space: pre-wrap; margin: 0 0 0.5rem; }
    .tag-row { display: flex; gap: 0.25rem; flex-wrap: wrap; margin-bottom: 0.5rem; }
    .meta-row { font-size: 0.75rem; color: var(--sapContent_LabelColor); margin-bottom: 0.5rem; }
    .action-row { display: flex; gap: 0.5rem; }
    .empty-state { text-align: center; padding: 3rem; color: var(--sapContent_LabelColor); }
  `]
})
export class PromptLibraryComponent implements OnInit, OnDestroy {
  private readonly http = inject(HttpClient);
  private readonly destroy$ = new Subject<void>();
  private readonly apiUrl = `${environment.apiBaseUrl}/prompts`;

  readonly prompts = signal<PromptTemplate[]>([]);
  readonly categories = signal<string[]>([]);
  readonly selectedCategory = signal<string | null>(null);
  readonly searchQuery = signal('');
  readonly showCreate = signal(false);
  readonly loading = signal(false);

  draftName = ''; draftContent = ''; draftCategory = 'general'; draftDescription = ''; draftTags = '';

  readonly filtered = computed(() => {
    let list = this.prompts();
    const cat = this.selectedCategory();
    if (cat) list = list.filter(p => p.category === cat);
    const q = this.searchQuery().toLowerCase().trim();
    if (q) list = list.filter(p => p.name.toLowerCase().includes(q) || p.description.toLowerCase().includes(q) || p.tags.some(t => t.includes(q)));
    return list;
  });

  ngOnInit(): void { this.loadPrompts(); this.loadCategories(); }
  ngOnDestroy(): void { this.destroy$.next(); this.destroy$.complete(); }

  loadPrompts(): void {
    this.loading.set(true);
    this.http.get<{ prompts: PromptTemplate[] }>(this.apiUrl).pipe(takeUntil(this.destroy$))
      .subscribe({ next: r => { this.prompts.set(r.prompts); this.loading.set(false); }, error: () => this.loading.set(false) });
  }


  loadCategories(): void {
    this.http.get<{ categories: string[] }>(`${this.apiUrl}/categories`).pipe(takeUntil(this.destroy$))
      .subscribe({ next: r => this.categories.set(r.categories), error: () => {} });
  }

  createPrompt(): void {
    const body = { name: this.draftName.trim(), content: this.draftContent.trim(), category: this.draftCategory.trim() || 'general', description: this.draftDescription.trim(), tags: this.draftTags.split(',').map(t => t.trim()).filter(Boolean) };
    this.http.post(this.apiUrl, body).pipe(takeUntil(this.destroy$))
      .subscribe({ next: () => { this.showCreate.set(false); this.draftName = ''; this.draftContent = ''; this.draftCategory = 'general'; this.draftDescription = ''; this.draftTags = ''; this.loadPrompts(); this.loadCategories(); } });
  }

  use(p: PromptTemplate): void { this.http.post(`${this.apiUrl}/${p.id}/use`, {}).pipe(takeUntil(this.destroy$)).subscribe(); navigator.clipboard?.writeText(p.content); }
  copy(p: PromptTemplate): void { navigator.clipboard?.writeText(p.content); }
  remove(p: PromptTemplate): void { this.http.delete(`${this.apiUrl}/${p.id}`).pipe(takeUntil(this.destroy$)).subscribe({ next: () => this.loadPrompts() }); }
}