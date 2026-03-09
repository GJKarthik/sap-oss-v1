import { bootstrapApplication } from '@angular/platform-browser';
import { provideRouter, Routes } from '@angular/router';
import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { provideAnimations } from '@angular/platform-browser/animations';

import { AppComponent } from './app/app.component';
import { DashboardComponent } from './app/dashboard/dashboard.component';
import { authInterceptor } from './app/interceptors/auth.interceptor';

const routes: Routes = [
  { path: '', redirectTo: '/dashboard', pathMatch: 'full' },
  { path: 'dashboard', component: DashboardComponent },
  { path: 'chat', loadComponent: () => import('./app/chat/chat.component').then(m => m.ChatComponent) },
  { path: 'models', loadComponent: () => import('./app/models/models.component').then(m => m.ModelsComponent) },
  { path: 'jobs', loadComponent: () => import('./app/jobs/jobs.component').then(m => m.JobsComponent) },
  { path: '**', redirectTo: '/dashboard' }
];

bootstrapApplication(AppComponent, {
  providers: [
    provideRouter(routes),
    provideHttpClient(withInterceptors([authInterceptor])),
    provideAnimations(),
  ]
}).catch(err => console.error(err));