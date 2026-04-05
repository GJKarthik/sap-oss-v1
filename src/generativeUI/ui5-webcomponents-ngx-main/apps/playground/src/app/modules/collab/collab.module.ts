// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { NgModule, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { GenUiCollabModule } from '@ui5/genui-collab';
import { environment } from '../../../environments/environment';
import { Ui5I18nModule } from '@ui5/webcomponents-ngx/i18n';
import { CollabDemoComponent } from './collab-demo.component';

const COLLAB_USER_ID_KEY = 'ui5-playground-collab-user-id';
const COLLAB_DISPLAY_NAME_KEY = 'ui5-playground-collab-display-name';
const COLLAB_TOKEN_KEY = 'ui5-playground-collab-token';

function getStoredValue(key: string): string | null {
  try {
    return globalThis.localStorage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

function setStoredValue(key: string, value: string): void {
  try {
    globalThis.localStorage?.setItem(key, value);
  } catch {
    // ignore storage failures in ephemeral/private contexts
  }
}

function resolvePlaygroundUserId(): string {
  const existing = getStoredValue(COLLAB_USER_ID_KEY);
  if (existing) return existing;
  const next = `playground-user-${Math.random().toString(36).slice(2, 10)}`;
  setStoredValue(COLLAB_USER_ID_KEY, next);
  return next;
}

function resolvePlaygroundDisplayName(userId: string): string {
  const existing = getStoredValue(COLLAB_DISPLAY_NAME_KEY);
  if (existing) return existing;
  const next = `Playground ${userId.slice(-4).toUpperCase()}`;
  setStoredValue(COLLAB_DISPLAY_NAME_KEY, next);
  return next;
}

const collabUserId = resolvePlaygroundUserId();
const collabDisplayName = resolvePlaygroundDisplayName(collabUserId);

@NgModule({
  declarations: [CollabDemoComponent],
  imports: [
    CommonModule,
    Ui5I18nModule,
    GenUiCollabModule.forRoot({
      websocketUrl: environment.collabWsUrl,
      userId: collabUserId,
      displayName: collabDisplayName,
      authTokenProvider: () => {
        const stored = getStoredValue(COLLAB_TOKEN_KEY);
        return stored || environment.collabAuthToken || undefined;
      },
    }),
    RouterModule.forChild([{ path: '', component: CollabDemoComponent }]),
  ],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
})
export class CollabModule {}
