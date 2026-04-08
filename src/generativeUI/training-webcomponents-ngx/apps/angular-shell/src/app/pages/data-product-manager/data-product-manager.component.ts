/**
 * Data Product Manager — browse, edit, and preview data products.
 *
 * Features:
 * - Card grid of all registered data products
 * - Detail panel with schema fields, team access, country views
 * - Prompt preview for any team × product combination
 * - Inline editing of x-team-access and x-country-views
 * - Skeleton loading, error/retry, empty states
 * - ARIA roles, keyboard navigation, focus management
 * - Entrance animations, responsive breakpoints
 */

import {
  Component,
  inject,
  signal,
  computed,
  OnInit,
  ElementRef,
  ViewChild,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';

import {
  DataProductService,
  ProductSummary,
  ProductDetail,
  PromptPreviewResponse,
} from '../../services/data-product.service';
import { TeamContextService } from '../../services/team-context.service';
import { ToastService } from '../../services/toast.service';
import { I18nService } from '../../services/i18n.service';

type ViewState = 'loading' | 'loaded' | 'error' | 'empty';

@Component({
  selector: 'app-data-product-manager',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="dpm" role="main" [attr.aria-label]="i18n.t('dpm.title')">
      <!-- ─── Header ─── -->
      <header class="dpm__header">
        <div>
          <h1 class="dpm__title">{{ i18n.t('dpm.title') }}</h1>
          <p class="dpm__subtitle" aria-live="polite">
            {{ i18n.t('dpm.productsRegistered', { count: products().length }) }}
            <span *ngIf="teamCtx.teamId() !== 'global'" class="dpm__scope-badge" role="status">
              {{ teamCtx.displayLabel() }}
            </span>
          </p>
        </div>
        <div class="dpm__actions">
          <button
            class="dpm__btn dpm__btn--primary"
            [disabled]="trainingJobId()"
            [attr.aria-busy]="!!trainingJobId()"
            (click)="generateTrainingData()">
            @if (trainingJobId()) {
              <span class="dpm__spinner" aria-hidden="true"></span>
              {{ i18n.t('dpm.generating') }}
            } @else {
              {{ i18n.t('dpm.generateTraining') }}
            }
          </button>
        </div>
      </header>

      <!-- ─── Loading Skeleton ─── -->
      @if (viewState() === 'loading' && !selectedProduct()) {
        <section class="dpm__grid" aria-busy="true" [attr.aria-label]="i18n.t('common.loading')">
          @for (i of skeletonCards; track i) {
            <div class="dpm__card dpm__card--skeleton" aria-hidden="true">
              <div class="skel skel--badge"></div>
              <div class="skel skel--title"></div>
              <div class="skel skel--text"></div>
              <div class="skel skel--text skel--short"></div>
            </div>
          }
        </section>
      }

      <!-- ─── Error State ─── -->
      @if (viewState() === 'error' && !selectedProduct()) {
        <div class="dpm__state" role="alert">
          <div class="dpm__state-icon">!</div>
          <p>{{ i18n.t('dpm.loadFailed') }}</p>
          <button class="dpm__btn dpm__btn--primary" (click)="loadProducts()">
            {{ i18n.t('common.refresh') }}
          </button>
        </div>
      }

      <!-- ─── Empty State ─── -->
      @if (viewState() === 'empty' && !selectedProduct()) {
        <div class="dpm__state">
          <div class="dpm__state-icon dpm__state-icon--empty">&#9744;</div>
          <p>{{ i18n.t('dpm.noSchema') }}</p>
        </div>
      }

      <!-- ─── Product Grid ─── -->
      @if (viewState() === 'loaded' && !selectedProduct()) {
        <section
          class="dpm__grid"
          role="list"
          [attr.aria-label]="i18n.t('nav.dataProducts')">
          @for (p of products(); track p.id; let idx = $index) {
            <article
              class="dpm__card"
              [class.dpm__card--enriched]="p.enrichmentAvailable"
              [style.animation-delay]="idx * 40 + 'ms'"
              role="listitem"
              tabindex="0"
              [attr.aria-label]="p.name + ' — ' + p.domain"
              (click)="selectProduct(p.id)"
              (keydown.enter)="selectProduct(p.id)"
              (keydown.space)="selectProduct(p.id); $event.preventDefault()">
              <div class="dpm__card-top">
                <span class="dpm__badge dpm__badge--domain">{{ p.domain }}</span>
                <span class="dpm__badge dpm__badge--security" [attr.data-level]="p.dataSecurityClass">
                  {{ p.dataSecurityClass }}
                </span>
              </div>
              <h3 class="dpm__card-title">{{ p.name }}</h3>
              <p class="dpm__card-desc">{{ p.description | slice:0:120 }}{{ p.description.length > 120 ? '…' : '' }}</p>
              <footer class="dpm__card-meta">
                <span>{{ i18n.t('dpm.fields', { count: p.fieldCount }) }}</span>
                <span *ngIf="p.hasCountryViews">{{ i18n.t('dpm.countryViews', { count: p.countryViewCount }) }}</span>
                <span *ngIf="p.enrichmentAvailable" class="dpm__meta-pill dpm__meta-pill--enriched">{{ i18n.t('dpm.enriched') }}</span>
              </footer>
              <div class="dpm__card-access" *ngIf="p.teamAccess?.['defaultAccess']">
                <span>{{ p.teamAccess['defaultAccess'] }}</span>
                <span *ngIf="p.teamAccess['domainRestrictions']?.length" class="dpm__access-domains">
                  {{ p.teamAccess['domainRestrictions'].join(', ') }}
                </span>
              </div>
            </article>
          }
        </section>
      }

      <!-- ─── Detail Panel ─── -->
      @if (selectedProduct()) {
        <section class="dpm__detail fadeSlideIn" role="region" [attr.aria-label]="selectedProduct()!.raw['dataProduct']?.['name']">
          <button
            #backBtn
            class="dpm__back"
            (click)="clearSelection()"
            [attr.aria-label]="i18n.t('dpm.back')">
            &larr; {{ i18n.t('dpm.back') }}
          </button>

          <div class="dpm__detail-header">
            <h2>{{ selectedProduct()!.raw['dataProduct']?.['name'] }}</h2>
            <span class="dpm__badge dpm__badge--domain">{{ selectedProduct()!.raw['dataProduct']?.['domain'] }}</span>
          </div>

          <!-- Tabs -->
          <div class="dpm__tabs" role="tablist" [attr.aria-label]="i18n.t('dpm.title')">
            @for (tab of tabs; track tab.key) {
              <button
                role="tab"
                [id]="'tab-' + tab.key"
                [attr.aria-selected]="activeTab() === tab.key"
                [attr.aria-controls]="'panel-' + tab.key"
                [class.dpm__tabs-active]="activeTab() === tab.key"
                (click)="activeTab.set(tab.key)"
                (keydown.arrowRight)="focusNextTab($event)"
                (keydown.arrowLeft)="focusPrevTab($event)">
                {{ i18n.t(tab.labelKey) }}
              </button>
            }
          </div>

          <!-- Schema Tab -->
          <div
            *ngIf="activeTab() === 'schema'"
            id="panel-schema" role="tabpanel" aria-labelledby="tab-schema"
            class="dpm__panel fadeIn">
            @if (schemaFields().length > 0) {
              <div class="dpm__table" role="table" [attr.aria-label]="i18n.t('dpm.tab.schema')">
                <div class="dpm__row dpm__row--header" role="row">
                  <span role="columnheader">Technical Name</span>
                  <span role="columnheader">Business Name</span>
                  <span role="columnheader">Type</span>
                  <span role="columnheader">Description</span>
                </div>
                @for (field of schemaFields(); track field.technicalName; let fi = $index) {
                  <div class="dpm__row" role="row" [style.animation-delay]="fi * 20 + 'ms'">
                    <span role="cell" class="dpm__mono">{{ field.technicalName }}</span>
                    <span role="cell">{{ field.businessName }}</span>
                    <span role="cell" class="dpm__mono dpm__muted">{{ field.dataType }}</span>
                    <span role="cell" class="dpm__muted">{{ field.description | slice:0:80 }}</span>
                  </div>
                }
              </div>
            } @else {
              <p class="dpm__empty-text">{{ i18n.t('dpm.noSchema') }}</p>
            }
          </div>

          <!-- Team Access Tab -->
          <div
            *ngIf="activeTab() === 'access'"
            id="panel-access" role="tabpanel" aria-labelledby="tab-access"
            class="dpm__panel fadeIn">
            <div class="dpm__form">
              <label class="dpm__label" for="access-level">{{ i18n.t('dpm.defaultAccess') }}</label>
              <select id="access-level" class="dpm__input" [(ngModel)]="editAccess.defaultAccess">
                <option value="read">Read</option>
                <option value="write">Write</option>
                <option value="admin">Admin</option>
                <option value="none">None</option>
              </select>

              <label class="dpm__label" for="domain-restrict">{{ i18n.t('dpm.domainRestrictions') }}</label>
              <input id="domain-restrict" class="dpm__input" type="text" [(ngModel)]="editAccess.domainRestrictionsStr" placeholder="treasury, esg" />

              <label class="dpm__label" for="country-restrict">{{ i18n.t('dpm.countryRestrictions') }}</label>
              <input id="country-restrict" class="dpm__input" type="text" [(ngModel)]="editAccess.countryRestrictionsStr" placeholder="AE, GB" />

              <button class="dpm__btn dpm__btn--primary" (click)="saveAccess()" [attr.aria-busy]="savingAccess()">
                {{ i18n.t('dpm.saveAccess') }}
              </button>
            </div>
          </div>

          <!-- Country Views Tab -->
          <div
            *ngIf="activeTab() === 'views'"
            id="panel-views" role="tabpanel" aria-labelledby="tab-views"
            class="dpm__panel fadeIn">
            @if (countryViews().length > 0) {
              @for (cv of countryViews(); track cv.country) {
                <details class="dpm__cv" open>
                  <summary class="dpm__cv-summary">{{ cv.country }}</summary>
                  <div class="dpm__cv-body">
                    <div *ngIf="cv.filters">
                      <strong>{{ i18n.t('dpm.defaultFilters') }}</strong>
                      <pre class="dpm__pre">{{ cv.filters | json }}</pre>
                    </div>
                    <div *ngIf="cv.promptAppend">
                      <strong>Prompt Append</strong>
                      <pre class="dpm__pre dpm__pre--dark">{{ cv.promptAppend }}</pre>
                    </div>
                    <div *ngIf="cv.glossary?.length">
                      <strong>{{ i18n.t('dpm.glossaryTerms') }} ({{ cv.glossary.length }})</strong>
                      <ul class="dpm__term-list">
                        <li *ngFor="let term of cv.glossary">
                          {{ term.source }} &rarr; {{ term.target }} <em>({{ term.lang }})</em>
                        </li>
                      </ul>
                    </div>
                  </div>
                </details>
              }
            } @else {
              <p class="dpm__empty-text">{{ i18n.t('dpm.noViews') }}</p>
            }
          </div>

          <!-- Prompt Preview Tab -->
          <div
            *ngIf="activeTab() === 'prompt'"
            id="panel-prompt" role="tabpanel" aria-labelledby="tab-prompt"
            class="dpm__panel fadeIn">
            <p class="dpm__muted">{{ i18n.t('dpm.promptHint') }}</p>
            <div class="dpm__form dpm__form--inline">
              <div>
                <label class="dpm__label" for="prompt-country">{{ i18n.t('dpm.countryOverride') }}</label>
                <input id="prompt-country" class="dpm__input" type="text" [(ngModel)]="promptPreviewCountry" placeholder="e.g. AE" />
              </div>
              <button
                class="dpm__btn dpm__btn--primary"
                [attr.aria-busy]="loadingPrompt()"
                (click)="loadPromptPreview()">
                {{ i18n.t('dpm.previewPrompt') }}
              </button>
            </div>

            @if (loadingPrompt()) {
              <div class="dpm__loading-bar" aria-hidden="true"></div>
            }

            @if (promptPreview()) {
              <div class="dpm__prompt-result fadeIn" role="region" [attr.aria-label]="i18n.t('dpm.tab.prompt')">
                <div class="dpm__scope-pill">{{ i18n.t('dpm.scope') }}: {{ promptPreview()!.scopeLabel }}</div>
                <pre class="dpm__pre dpm__pre--dark">{{ promptPreview()!.effectivePrompt }}</pre>
                @if (promptPreview()!.glossaryTerms.length > 0) {
                  <h4>{{ i18n.t('dpm.glossaryTerms') }}</h4>
                  <ul class="dpm__term-list">
                    <li *ngFor="let t of promptPreview()!.glossaryTerms">
                      {{ t.source }} &rarr; {{ t.target }} ({{ t.lang }})
                    </li>
                  </ul>
                }
                @if (objectKeys(promptPreview()!.filters).length > 0) {
                  <h4>{{ i18n.t('dpm.defaultFilters') }}</h4>
                  <pre class="dpm__pre">{{ promptPreview()!.filters | json }}</pre>
                }
              </div>
            }
          </div>

          <!-- Enrichment Tab -->
          <div
            *ngIf="activeTab() === 'enrichment'"
            id="panel-enrichment" role="tabpanel" aria-labelledby="tab-enrichment"
            class="dpm__panel fadeIn">
            @if (selectedProduct()!.enrichment) {
              <pre class="dpm__pre dpm__pre--scroll">{{ selectedProduct()!.enrichment | json }}</pre>
            } @else {
              <p class="dpm__empty-text">{{ i18n.t('dpm.noEnrichment') }}</p>
            }
          </div>
        </section>
      }
    </div>
  `,
  styles: [`
    /* ── Keyframes ── */
    @keyframes fadeSlideUp {
      from { opacity: 0; transform: translateY(12px); }
      to   { opacity: 1; transform: translateY(0); }
    }
    @keyframes fadeSlideIn {
      from { opacity: 0; transform: translateX(-16px); }
      to   { opacity: 1; transform: translateX(0); }
    }
    @keyframes fadeIn {
      from { opacity: 0; }
      to   { opacity: 1; }
    }
    @keyframes shimmer {
      to { background-position: -200% 0; }
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    @keyframes pulseBar {
      0%, 100% { transform: scaleX(0.3); }
      50% { transform: scaleX(1); }
    }

    .fadeSlideIn { animation: fadeSlideIn 0.35s cubic-bezier(0.22, 1, 0.36, 1) both; }
    .fadeIn      { animation: fadeIn 0.25s ease both; }

    /* ── Layout ── */
    .dpm { padding: 1.5rem; max-width: 1440px; margin: 0 auto; }
    .dpm__header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 1.5rem; gap: 1rem; flex-wrap: wrap; }
    .dpm__title { font-size: 1.5rem; font-weight: 700; margin: 0; letter-spacing: -0.02em; }
    .dpm__subtitle { color: var(--sapContent_LabelColor, #666); margin: 0.25rem 0 0; font-size: 0.875rem; }
    .dpm__scope-badge {
      display: inline-block; background: var(--sapInformationBackground, #e8f4fd); color: var(--sapBrandColor, #0a6ed1);
      padding: 0.125rem 0.5rem; border-radius: 100px; font-size: 0.7rem; margin-inline-start: 0.5rem;
      font-weight: 600;
    }
    .dpm__actions { flex-shrink: 0; }

    /* ── Buttons ── */
    .dpm__btn {
      padding: 0.5rem 1.25rem; border: none; border-radius: 8px; cursor: pointer;
      font-size: 0.8125rem; font-weight: 600; display: inline-flex; align-items: center; gap: 0.5rem;
      transition: background 0.15s, transform 0.1s, box-shadow 0.15s;
    }
    .dpm__btn:active { transform: scale(0.97); }
    .dpm__btn--primary {
      background: var(--sapBrandColor, #0a6ed1); color: #fff;
      box-shadow: 0 1px 3px rgba(10,110,209,0.25);
    }
    .dpm__btn--primary:hover:not(:disabled) { background: #085bb5; box-shadow: 0 4px 12px rgba(10,110,209,0.3); }
    .dpm__btn:disabled { opacity: 0.6; cursor: not-allowed; }
    .dpm__spinner { width: 14px; height: 14px; border: 2px solid rgba(255,255,255,0.3); border-top-color: #fff; border-radius: 50%; animation: spin 0.6s linear infinite; }

    /* ── Skeleton ── */
    .dpm__card--skeleton { pointer-events: none; }
    .skel {
      border-radius: 6px; background: linear-gradient(90deg, #f0f0f0 25%, #e8e8e8 50%, #f0f0f0 75%);
      background-size: 200% 100%; animation: shimmer 1.5s ease infinite;
    }
    .skel--badge { width: 60px; height: 18px; margin-bottom: 0.75rem; }
    .skel--title { width: 70%; height: 20px; margin-bottom: 0.5rem; }
    .skel--text  { width: 100%; height: 14px; margin-bottom: 0.375rem; }
    .skel--short { width: 40%; }

    /* ── State Pages (error / empty) ── */
    .dpm__state {
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      padding: 4rem 2rem; text-align: center; gap: 1rem;
    }
    .dpm__state-icon {
      width: 56px; height: 56px; border-radius: 50%; display: grid; place-items: center;
      font-size: 1.5rem; font-weight: 700; color: #fff; background: #e65100;
    }
    .dpm__state-icon--empty { background: #bdbdbd; }
    .dpm__state p { color: var(--sapContent_LabelColor, #666); max-width: 320px; }

    /* ── Grid ── */
    .dpm__grid {
      display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1rem;
    }

    /* ── Cards ── */
    .dpm__card {
      background: var(--sapTile_Background, #fff); border: 1px solid var(--sapTile_BorderColor, #e0e0e0);
      border-radius: 12px; padding: 1.25rem; cursor: pointer;
      transition: box-shadow 0.2s cubic-bezier(0.22,1,0.36,1), border-color 0.2s, transform 0.2s;
      animation: fadeSlideUp 0.4s cubic-bezier(0.22,1,0.36,1) both;
      outline: none;
    }
    .dpm__card:hover, .dpm__card:focus-visible {
      box-shadow: 0 8px 24px rgba(0,0,0,0.08); border-color: var(--sapBrandColor, #0a6ed1);
      transform: translateY(-2px);
    }
    .dpm__card:focus-visible { outline: 2px solid var(--sapBrandColor, #0a6ed1); outline-offset: 2px; }
    .dpm__card--enriched { border-inline-start: 3px solid #2e7d32; }
    .dpm__card-top { display: flex; justify-content: space-between; margin-bottom: 0.5rem; }
    .dpm__card-title { margin: 0.5rem 0 0.25rem; font-size: 1.05rem; font-weight: 600; }
    .dpm__card-desc { color: var(--sapContent_LabelColor, #555); font-size: 0.825rem; margin: 0 0 0.75rem; line-height: 1.5; }
    .dpm__card-meta { display: flex; flex-wrap: wrap; gap: 0.625rem; font-size: 0.7rem; color: #888; }
    .dpm__card-access { margin-top: 0.5rem; font-size: 0.7rem; color: #888; display: flex; gap: 0.75rem; }
    .dpm__access-domains { opacity: 0.7; }

    /* ── Badges & Pills ── */
    .dpm__badge {
      font-size: 0.675rem; padding: 0.125rem 0.5rem; border-radius: 100px; font-weight: 600;
      text-transform: uppercase; letter-spacing: 0.03em;
    }
    .dpm__badge--domain { background: var(--sapNeutralBackground, #f0f0f0); color: var(--sapContent_LabelColor, #555); }
    .dpm__badge--security { background: #fff3e0; color: #e65100; }
    .dpm__badge--security[data-level="restricted"] { background: #fce4ec; color: #c62828; }
    .dpm__meta-pill { padding: 0.0625rem 0.375rem; border-radius: 100px; font-weight: 500; }
    .dpm__meta-pill--enriched { background: #e8f5e9; color: #2e7d32; }
    .dpm__scope-pill {
      display: inline-block; font-size: 0.7rem; font-weight: 600; padding: 0.125rem 0.625rem;
      border-radius: 100px; background: var(--sapInformationBackground, #e8f4fd);
      color: var(--sapBrandColor, #0a6ed1); margin-bottom: 0.5rem;
    }

    /* ── Detail Panel ── */
    .dpm__back {
      background: none; border: none; color: var(--sapBrandColor, #0a6ed1); cursor: pointer;
      font-size: 0.8125rem; font-weight: 600; padding: 0; margin-bottom: 1rem;
      transition: opacity 0.15s;
    }
    .dpm__back:hover { opacity: 0.7; }
    .dpm__detail-header { display: flex; align-items: center; gap: 0.75rem; margin-bottom: 1rem; }
    .dpm__detail-header h2 { margin: 0; font-size: 1.25rem; font-weight: 700; letter-spacing: -0.02em; }

    /* ── Tabs ── */
    .dpm__tabs {
      display: flex; gap: 0; border-bottom: 2px solid var(--sapGroup_TitleBorderColor, #e0e0e0);
      margin-bottom: 1rem; overflow-x: auto; scrollbar-width: none;
    }
    .dpm__tabs::-webkit-scrollbar { display: none; }
    .dpm__tabs button {
      background: none; border: none; padding: 0.625rem 1.125rem; cursor: pointer;
      font-size: 0.8125rem; font-weight: 500; color: var(--sapContent_LabelColor, #666);
      border-bottom: 2px solid transparent; margin-bottom: -2px;
      transition: color 0.15s, border-color 0.2s; white-space: nowrap; flex-shrink: 0;
    }
    .dpm__tabs button:focus-visible { outline: 2px solid var(--sapBrandColor, #0a6ed1); outline-offset: -2px; border-radius: 4px 4px 0 0; }
    .dpm__tabs-active { color: var(--sapBrandColor, #0a6ed1) !important; border-bottom-color: var(--sapBrandColor, #0a6ed1) !important; font-weight: 600 !important; }
    .dpm__tabs button:hover { color: var(--sapBrandColor, #0a6ed1); }

    /* ── Panels ── */
    .dpm__panel { min-height: 260px; }

    /* ── Table ── */
    .dpm__table { border: 1px solid var(--sapGroup_TitleBorderColor, #e0e0e0); border-radius: 8px; overflow: hidden; }
    .dpm__row {
      display: grid; grid-template-columns: 1fr 1fr 0.6fr 1.5fr;
      padding: 0.5rem 0.75rem; font-size: 0.8rem; border-bottom: 1px solid #f5f5f5;
      animation: fadeSlideUp 0.3s cubic-bezier(0.22,1,0.36,1) both;
    }
    .dpm__row--header {
      background: var(--sapList_HeaderBackground, #fafafa); font-weight: 600;
      font-size: 0.7rem; text-transform: uppercase; color: #888; letter-spacing: 0.03em;
      animation: none;
    }
    .dpm__mono { font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace; font-size: 0.775rem; }
    .dpm__muted { color: var(--sapContent_LabelColor, #888); }

    /* ── Forms ── */
    .dpm__form { display: flex; flex-direction: column; gap: 0.875rem; max-width: 440px; }
    .dpm__form--inline { flex-direction: row; align-items: flex-end; gap: 0.75rem; max-width: 100%; flex-wrap: wrap; }
    .dpm__label { font-size: 0.75rem; font-weight: 600; color: var(--sapContent_LabelColor, #555); margin-bottom: 0.125rem; display: block; }
    .dpm__input {
      width: 100%; padding: 0.5rem 0.75rem; border: 1px solid var(--sapField_BorderColor, #d0d0d0);
      border-radius: 8px; font-size: 0.8125rem; transition: border-color 0.15s, box-shadow 0.15s;
      background: var(--sapField_Background, #fff);
    }
    .dpm__input:focus { border-color: var(--sapBrandColor, #0a6ed1); box-shadow: 0 0 0 3px rgba(10,110,209,0.12); outline: none; }

    /* ── Country Views ── */
    .dpm__cv { border: 1px solid var(--sapGroup_TitleBorderColor, #e8e8e8); border-radius: 10px; margin-bottom: 0.625rem; overflow: hidden; }
    .dpm__cv-summary {
      padding: 0.75rem 1rem; cursor: pointer; font-weight: 600; font-size: 0.875rem;
      background: var(--sapList_HeaderBackground, #fafafa); user-select: none;
    }
    .dpm__cv-body { padding: 0.75rem 1rem; font-size: 0.825rem; }
    .dpm__cv-body > div { margin-bottom: 0.5rem; }

    /* ── Pre / Code Blocks ── */
    .dpm__pre {
      background: var(--sapList_HeaderBackground, #fafafa); padding: 0.875rem; border-radius: 8px;
      font-size: 0.775rem; line-height: 1.6; white-space: pre-wrap; overflow-x: auto;
      border: 1px solid #e8e8e8;
    }
    .dpm__pre--dark {
      background: #1e1e2e; color: #cdd6f4; border-color: #313244;
    }
    .dpm__pre--scroll { max-height: 500px; overflow: auto; }

    .dpm__term-list { padding-inline-start: 1.25rem; font-size: 0.8rem; }
    .dpm__term-list li { margin-bottom: 0.25rem; }
    .dpm__term-list em { opacity: 0.6; }

    /* ── Loading bar ── */
    .dpm__loading-bar {
      height: 3px; background: var(--sapBrandColor, #0a6ed1); border-radius: 2px;
      margin: 0.5rem 0 1rem; transform-origin: left;
      animation: pulseBar 1.2s ease-in-out infinite;
    }

    /* ── Prompt result ── */
    .dpm__prompt-result { margin-top: 1rem; }

    /* ── Empty text ── */
    .dpm__empty-text { color: var(--sapContent_LabelColor, #999); font-style: italic; text-align: center; padding: 2rem 1rem; }

    /* ── Responsive ── */
    @media (max-width: 900px) {
      .dpm { padding: 1rem; }
      .dpm__grid { grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); }
      .dpm__row { grid-template-columns: 1fr 1fr; gap: 0.25rem; }
      .dpm__row span:nth-child(3), .dpm__row span:nth-child(4) { display: none; }
      .dpm__row--header span:nth-child(3), .dpm__row--header span:nth-child(4) { display: none; }
      .dpm__form--inline { flex-direction: column; align-items: stretch; }
    }
    @media (max-width: 600px) {
      .dpm__header { flex-direction: column; }
      .dpm__grid { grid-template-columns: 1fr; }
      .dpm__tabs button { padding: 0.5rem 0.75rem; font-size: 0.75rem; }
    }
  `],
})
export class DataProductManagerComponent implements OnInit {
  private readonly dp = inject(DataProductService);
  readonly teamCtx = inject(TeamContextService);
  private readonly toast = inject(ToastService);
  readonly i18n = inject(I18nService);

  @ViewChild('backBtn') backBtn?: ElementRef<HTMLButtonElement>;

  readonly products = signal<ProductSummary[]>([]);
  readonly selectedProduct = signal<ProductDetail | null>(null);
  readonly activeTab = signal<string>('schema');
  readonly promptPreview = signal<PromptPreviewResponse | null>(null);
  readonly trainingJobId = signal<string | null>(null);
  readonly viewState = signal<ViewState>('loading');
  readonly loadingPrompt = signal(false);
  readonly savingAccess = signal(false);
  readonly detailLoading = signal(false);

  promptPreviewCountry = '';
  readonly skeletonCards = [0, 1, 2, 3, 4, 5];

  editAccess = {
    defaultAccess: 'read',
    domainRestrictionsStr: '',
    countryRestrictionsStr: '',
  };

  readonly tabs = [
    { key: 'schema', labelKey: 'dpm.tab.schema' },
    { key: 'access', labelKey: 'dpm.tab.access' },
    { key: 'views', labelKey: 'dpm.tab.views' },
    { key: 'prompt', labelKey: 'dpm.tab.prompt' },
    { key: 'enrichment', labelKey: 'dpm.tab.enrichment' },
  ];

  readonly schemaFields = computed(() => {
    const detail = this.selectedProduct();
    if (!detail) return [];
    const dp = detail.raw['dataProduct'] || {};
    const fields: Array<{ technicalName: string; businessName: string; dataType: string; description: string }> = [];

    for (const portKey of ['inputPorts', 'outputPorts']) {
      const ports = dp[portKey];
      if (Array.isArray(ports)) {
        for (const port of ports) {
          for (const f of (port.fields || port.columns || [])) {
            fields.push({
              technicalName: f.technicalName || f.name || '',
              businessName: f.businessName || f.label || '',
              dataType: f.dataType || f.type || '',
              description: f.description || '',
            });
          }
        }
      }
    }

    const schema = dp['schema'];
    if (Array.isArray(schema)) {
      for (const f of schema) {
        fields.push({
          technicalName: f.technicalName || f.name || '',
          businessName: f.businessName || f.label || '',
          dataType: f.dataType || f.type || '',
          description: f.description || '',
        });
      }
    }

    return fields;
  });

  readonly countryViews = computed(() => {
    const detail = this.selectedProduct();
    if (!detail) return [];
    const views = detail.raw['dataProduct']?.['x-country-views'] || {};
    return Object.entries(views).map(([country, view]: [string, any]) => ({
      country,
      filters: view.defaultFilters || null,
      promptAppend: view.promptAppend || '',
      glossary: view.additionalGlossary || [],
    }));
  });

  objectKeys = Object.keys;

  ngOnInit(): void {
    this.loadProducts();
  }

  loadProducts(): void {
    this.viewState.set('loading');
    this.dp.listProducts().subscribe({
      next: (products) => {
        this.products.set(products);
        this.viewState.set(products.length > 0 ? 'loaded' : 'empty');
      },
      error: () => {
        this.viewState.set('error');
        this.toast.error(this.i18n.t('dpm.loadFailed'));
      },
    });
  }

  selectProduct(productId: string): void {
    this.detailLoading.set(true);
    this.dp.getProduct(productId).subscribe({
      next: (detail) => {
        this.selectedProduct.set(detail);
        this.activeTab.set('schema');
        this.promptPreview.set(null);
        this.promptPreviewCountry = this.teamCtx.country();
        this.detailLoading.set(false);

        const access = detail.raw['dataProduct']?.['x-team-access'] || {};
        this.editAccess = {
          defaultAccess: access.defaultAccess || 'read',
          domainRestrictionsStr: (access.domainRestrictions || []).join(', '),
          countryRestrictionsStr: (access.countryRestrictions || []).join(', '),
        };

        // Focus management: shift focus into detail panel after render
        setTimeout(() => this.backBtn?.nativeElement?.focus(), 80);
      },
      error: () => {
        this.detailLoading.set(false);
        this.toast.error(this.i18n.t('dpm.detailFailed'));
      },
    });
  }

  clearSelection(): void {
    this.selectedProduct.set(null);
    this.promptPreview.set(null);
  }

  saveAccess(): void {
    const detail = this.selectedProduct();
    if (!detail) return;

    this.savingAccess.set(true);
    const teamAccess = {
      defaultAccess: this.editAccess.defaultAccess,
      domainRestrictions: this.editAccess.domainRestrictionsStr
        ? this.editAccess.domainRestrictionsStr.split(',').map((s: string) => s.trim()).filter(Boolean)
        : [],
      countryRestrictions: this.editAccess.countryRestrictionsStr
        ? this.editAccess.countryRestrictionsStr.split(',').map((s: string) => s.trim()).filter(Boolean)
        : [],
    };

    this.dp.updateProduct(detail.id, { teamAccess }).subscribe({
      next: () => {
        this.savingAccess.set(false);
        this.toast.success(this.i18n.t('dpm.accessSaved'));
        this.loadProducts();
      },
      error: () => {
        this.savingAccess.set(false);
        this.toast.error(this.i18n.t('dpm.accessFailed'));
      },
    });
  }

  loadPromptPreview(): void {
    const detail = this.selectedProduct();
    if (!detail) return;

    this.loadingPrompt.set(true);
    this.dp.previewPrompt({
      productId: detail.id,
      country: this.promptPreviewCountry || this.teamCtx.country(),
      domain: this.teamCtx.domain(),
    }).subscribe({
      next: (preview) => {
        this.loadingPrompt.set(false);
        this.promptPreview.set(preview);
      },
      error: () => {
        this.loadingPrompt.set(false);
        this.toast.error(this.i18n.t('dpm.promptFailed'));
      },
    });
  }

  generateTrainingData(): void {
    const team = this.teamCtx.teamId();
    this.dp.triggerTrainingGeneration({
      team: team !== 'global' ? team : '',
    }).subscribe({
      next: (result) => {
        this.trainingJobId.set(result.job_id);
        this.toast.success(this.i18n.t('dpm.trainingStarted', { jobId: result.job_id }));
      },
      error: () => this.toast.error(this.i18n.t('dpm.trainingFailed')),
    });
  }

  /** Keyboard arrow navigation between tabs */
  focusNextTab(event: KeyboardEvent): void {
    const btn = event.target as HTMLElement;
    const next = btn.nextElementSibling as HTMLElement | null;
    if (next) { next.focus(); }
  }

  focusPrevTab(event: KeyboardEvent): void {
    const btn = event.target as HTMLElement;
    const prev = btn.previousElementSibling as HTMLElement | null;
    if (prev) { prev.focus(); }
  }
}
