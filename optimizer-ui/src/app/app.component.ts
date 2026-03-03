import { Component } from '@angular/core';
import { RouterOutlet } from '@angular/router';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [RouterOutlet],
  template: `
    <ui5-shellbar
      primary-title="Model Optimizer"
      secondary-title="T4 GPU Quantization Pipeline"
      show-notifications
      show-product-switch>
    </ui5-shellbar>
    
    <div class="app-content">
      <router-outlet></router-outlet>
    </div>
  `,
  styles: [`
    :host {
      display: block;
      height: 100vh;
    }
    .app-content {
      padding: 1rem;
      height: calc(100vh - 44px);
      overflow: auto;
    }
  `]
})
export class AppComponent {
  title = 'Model Optimizer';
}