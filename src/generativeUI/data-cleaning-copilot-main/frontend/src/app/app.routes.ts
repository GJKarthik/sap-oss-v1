// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
import { Routes } from '@angular/router';

export const routes: Routes = [
    {
        path: '',
        redirectTo: 'dashboard',
        pathMatch: 'full',
    },
    {
        path: 'dashboard',
        loadComponent: () =>
            import('./data-quality-dashboard/data-quality-dashboard.component').then(
                (m) => m.DataQualityDashboardComponent
            ),
        title: 'Data Quality Dashboard',
    },
    {
        path: 'approvals',
        loadComponent: () =>
            import('./approval-workflow/approval-workflow.component').then(
                (m) => m.ApprovalWorkflowComponent
            ),
        title: 'Query Approval Workflow',
    },
    {
        path: 'lineage',
        loadComponent: () =>
            import('./lineage-graph/lineage-graph.component').then((m) => m.LineageGraphComponent),
        title: 'Data Lineage',
    },
    {
        path: 'training',
        loadComponent: () =>
            import('./training-products/training-products.component').then(
                (m) => m.TrainingProductsComponent
            ),
        title: 'Training Products',
    },
    {
        path: '**',
        redirectTo: 'dashboard',
    },
];