import { Component, CUSTOM_ELEMENTS_SCHEMA, ChangeDetectionStrategy, effect, inject } from '@angular/core';
import { RouterOutlet } from '@angular/router';
import { ToastComponent } from './components/toast/toast.component';
import { WorkspaceService } from './services/workspace.service';
import { normalizeWorkspaceTheme } from './services/workspace.types';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [RouterOutlet, ToastComponent],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <router-outlet />
    <app-toast />
  `,
})
export class AppComponent {
  private readonly workspace = inject(WorkspaceService);

  constructor() {
    effect(() => {
      const theme = normalizeWorkspaceTheme(this.workspace.settings().theme);
      document.documentElement.setAttribute('data-sap-theme', theme);
    });
  }
}
