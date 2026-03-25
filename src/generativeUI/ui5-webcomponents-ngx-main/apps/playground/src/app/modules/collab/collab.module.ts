// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { NgModule, CUSTOM_ELEMENTS_SCHEMA } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { GenUiCollabModule } from '@ui5/genui-collab';
import { environment } from '../../../environments/environment';
import { CollabDemoComponent } from './collab-demo.component';

@NgModule({
  declarations: [CollabDemoComponent],
  imports: [
    CommonModule,
    GenUiCollabModule.forRoot({
      websocketUrl: environment.collabWsUrl,
      // TODO: replace with authenticated user ID and display name from an auth service
      userId: 'playground-user-' + Math.random().toString(36).slice(2, 7),
      displayName: 'Playground User',
    }),
    RouterModule.forChild([{ path: '', component: CollabDemoComponent }]),
  ],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
})
export class CollabModule {}
