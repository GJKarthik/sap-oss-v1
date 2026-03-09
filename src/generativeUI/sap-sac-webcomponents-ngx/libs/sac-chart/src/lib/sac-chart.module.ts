/**
 * SAC Chart Module
 *
 * Angular module for SAC Chart visualization components.
 * Selector: sac-chart (from mangle/sac_widget.mg)
 */

import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';

import { SacChartComponent } from './components/sac-chart.component';

@NgModule({
  imports: [CommonModule],
  declarations: [SacChartComponent],
  exports: [SacChartComponent],
})
export class SacChartModule {}
