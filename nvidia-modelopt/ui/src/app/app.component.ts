import { Component } from '@angular/core';
import { RouterOutlet, RouterLink, RouterLinkActive } from '@angular/router';
import { CommonModule } from '@angular/common';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [CommonModule, RouterOutlet, RouterLink, RouterLinkActive],
  template: `
    <div class="app-container">
      <nav class="sidebar">
        <div class="logo">
          <img src="assets/nvidia-logo.svg" alt="NVIDIA" class="nvidia-logo">
          <span>Model Optimizer</span>
        </div>
        <ul class="nav-menu">
          <li>
            <a routerLink="/dashboard" routerLinkActive="active">
              <span class="icon">📊</span>
              <span>Dashboard</span>
            </a>
          </li>
          <li>
            <a routerLink="/chat" routerLinkActive="active">
              <span class="icon">💬</span>
              <span>Chat</span>
            </a>
          </li>
          <li>
            <a routerLink="/models" routerLinkActive="active">
              <span class="icon">🤖</span>
              <span>Models</span>
            </a>
          </li>
          <li>
            <a routerLink="/jobs" routerLinkActive="active">
              <span class="icon">⚙️</span>
              <span>Jobs</span>
            </a>
          </li>
        </ul>
        <div class="sidebar-footer">
          <div class="api-key-section">
            <input 
              type="password" 
              [value]="apiKey"
              (input)="onApiKeyChange($event)"
              placeholder="API Key"
            >
            <button (click)="saveApiKey()">Save</button>
          </div>
        </div>
      </nav>
      <main class="content">
        <router-outlet></router-outlet>
      </main>
    </div>
  `,
  styles: [`
    .app-container {
      display: flex;
      min-height: 100vh;
      background: #f5f5f5;
    }
    .sidebar {
      width: 250px;
      background: #1a1a1a;
      color: white;
      display: flex;
      flex-direction: column;
    }
    .logo {
      padding: 20px;
      display: flex;
      align-items: center;
      gap: 10px;
      border-bottom: 1px solid #333;
    }
    .logo img {
      height: 30px;
    }
    .logo span {
      font-weight: bold;
      color: #76b900;
    }
    .nav-menu {
      list-style: none;
      padding: 0;
      margin: 0;
      flex: 1;
    }
    .nav-menu li a {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 15px 20px;
      color: #ccc;
      text-decoration: none;
      transition: all 0.2s;
    }
    .nav-menu li a:hover {
      background: #333;
      color: white;
    }
    .nav-menu li a.active {
      background: #76b900;
      color: white;
    }
    .nav-menu .icon {
      font-size: 18px;
    }
    .sidebar-footer {
      padding: 20px;
      border-top: 1px solid #333;
    }
    .api-key-section {
      display: flex;
      gap: 8px;
    }
    .api-key-section input {
      flex: 1;
      padding: 8px;
      border: 1px solid #444;
      border-radius: 4px;
      background: #333;
      color: white;
      font-size: 12px;
    }
    .api-key-section button {
      padding: 8px 12px;
      background: #76b900;
      color: white;
      border: none;
      border-radius: 4px;
      cursor: pointer;
      font-size: 12px;
    }
    .content {
      flex: 1;
      overflow-y: auto;
    }
  `]
})
export class AppComponent {
  apiKey = '';
  
  constructor() {
    this.apiKey = localStorage.getItem('modelopt_api_key') || '';
  }
  
  onApiKeyChange(event: Event): void {
    const input = event.target as HTMLInputElement;
    this.apiKey = input.value;
  }
  
  saveApiKey(): void {
    localStorage.setItem('modelopt_api_key', this.apiKey);
    alert('API Key saved');
  }
}