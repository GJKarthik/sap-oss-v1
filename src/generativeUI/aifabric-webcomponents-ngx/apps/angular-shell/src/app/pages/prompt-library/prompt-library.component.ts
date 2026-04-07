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
  imports: [CommonModule, FormsModule, Ui5WebcomponentsModule, EmptyStateComponent, DateFormatPipe],
  template: `
    <ui5-page background-design="Solid">
      <ui5-bar slot="header" design="Header">
        <ui5-title slot="startContent" level="H3">Prompt Library</ui5-title>
        <ui5-input slot="endContent" placeholder="Search prompts..." [value]="searchQuery" (input)="onSearch($event)" style="min-width: 200px;"></ui5-input>
        <ui5-button slot="endContent" design="Emphasized" icon="add" (click)="showCreateForm = !showCreateForm">
          {{ showCreateForm ? 'Cancel' : 'New Prompt' }}
        </ui5-button>
      </ui5-bar>

      <div class="library-content">
        <!-- Category filter -->
        <div class="category-bar">
          <ui5-button *ngFor="let cat of categories" [design]="selectedCategory === cat ? 'Emphasized' : 'Default'" (click)="filterByCategory(cat)">{{ cat }}</ui5-button>
          <ui5-button *ngIf="selectedCategory" design="Transparent" (click)="filterByCategory(null)">Clear filter</ui5-button>
        </div>

        <!-- Create form -->
        <ui5-card *ngIf="showCreateForm" class="create-card">
          <ui5-card-header slot="header" title-text="New Prompt Template"></ui5-card-header>
          <div class="form-grid">
            <ui5-input ngDefaultControl [(ngModel)]="draft.name" name="name" placeholder="Prompt name" required></ui5-input>
            <ui5-input ngDefaultControl [(ngModel)]="draft.category" name="category" placeholder="Category"></ui5-input>
            <ui5-input ngDefaultControl [(ngModel)]="draft.description" name="description" placeholder="Description"></ui5-input>
            <ui5-textarea ngDefaultControl [(ngModel)]="draft.content" name="content" [placeholder]="'Prompt content (use {'+'{variable}'+'}  for placeholders)'" [rows]="5" growing></ui5-textarea>
            <ui5-input ngDefaultControl [(ngModel)]="draft.tagsStr" name="tags" placeholder="Tags (comma-separated)"></ui5-input>
            <div class="form-actions">
              <ui5-button design="Emphasized" (click)="createPrompt()" [disabled]="!draft.name.trim() || !draft.content.trim()">Create</ui5-button>
              <ui5-button design="Transparent" (click)="showCreateForm = false">Cancel</ui5-button>
            </div>
          </div>
        </ui5-card>

        <!-- Prompt cards -->
        <div class="prompt-grid">
          <ui5-card *ngFor="let prompt of filteredPrompts; trackBy: trackById" class="prompt-card">
            <ui5-card-header slot="header" [titleText]="prompt.name" [subtitleText]="prompt.category" [additionalText]="prompt.usage_count + ' uses'"></ui5-card-header>
            <div class="prompt-body">
              <p class="prompt-desc">{{ prompt.description || 'No description' }}</p>
              <pre class="prompt-content">{{ prompt.content }}</pre>
              <div class="prompt-tags">
                <ui5-tag *ngFor="let tag of prompt.tags" design="Information">{{ tag }}</ui5-tag>
              </div>
              <div class="prompt-meta">
                <span>v{{ prompt.version }} · by {{ prompt.created_by }}</span>
                <span>{{ prompt.updated_at | dateFormat:'short' }}</span>
              </div>
              <div class="prompt-actions">
                <ui5-button design="Default" icon="copy" (click)="copyPrompt(prompt)">Copy</ui5-button>
                <ui5-button design="Positive" icon="accept" (click)="usePrompt(prompt)">Use</ui5-button>
                <ui5-button design="Negative" icon="delete" (click)="deletePrompt(prompt)">Delete</ui5-button>
              </div>
            </div>
          </ui5-card>
        </div>

        <app-empty-state *ngIf="filteredPrompts.length === 0 && !loading" icon="document" title="No Prompts Found" description="Create your first shared prompt template for the team."></app-empty-state>
      </div>
    </ui5-page>
  `,

  styles: [`
    .library-content { padding: 1rem; max-width: 1200px; margin: 0 auto; display: flex; flex-direction: column; gap: 1rem; }
    .category-bar { display: flex; gap: 0.5rem; flex-wrap: wrap; }
    .create-card { max-width: 600px; }
    .form-grid { padding: 1rem; display: grid; gap: 0.75rem; }
    .form-actions { display: flex; gap: 0.5rem; }
    .prompt-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(350px, 1fr)); gap: 1rem; }
    .prompt-body { padding: 0.75rem; }
    .prompt-desc { font-size: 0.875rem; margin: 0 0 0.5rem; }
    .prompt-content { background: var(--sapShell_Background, #f5f6f7); padding: 0.75rem; border-radius: 0.25rem; font-size: 0.75rem; max-height: 120px; overflow: auto; white-space: pre-wrap; margin: 0 0 0.5rem; }
    .prompt-tags { display: flex; gap: 0.25rem; flex-wrap: wrap; margin-bottom: 0.5rem; }
    .prompt-meta { display: flex; justify-content: space-between; font-size: 0.75rem; color: var(--sapContent_LabelColor); margin-bottom: 0.5rem; }
    .prompt-actions { display: flex; gap: 0.5rem; }
  `]
})
export class PromptLibraryComponent implements OnInit {
  private readonly http = inject(HttpClient);
  private readonly destroyRef = inject(DestroyRef);
  private readonly apiUrl = `${environment.apiBaseUrl}/prompts`;

  prompts: PromptTemplate[] = [];
  filteredPrompts: PromptTemplate[] = [];
  categories: string[] = [];
  selectedCategory: string | null = null;
  searchQuery = '';
  loading = false;
  showCreateForm = false;
  draft = { name: '', content: '', category: 'general', description: '', tagsStr: '' };

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

  usePrompt(p: PromptTemplate): void { this.http.post(`${this.apiUrl}/${p.id}/use`, {}).pipe(takeUntilDestroyed(this.destroyRef)).subscribe(); navigator.clipboard?.writeText(p.content); }
  copyPrompt(p: PromptTemplate): void { navigator.clipboard?.writeText(p.content); }
  deletePrompt(p: PromptTemplate): void { this.http.delete(`${this.apiUrl}/${p.id}`).pipe(takeUntilDestroyed(this.destroyRef)).subscribe({ next: () => this.loadPrompts() }); }
  trackById(_: number, item: PromptTemplate): string { return item.id; }
}