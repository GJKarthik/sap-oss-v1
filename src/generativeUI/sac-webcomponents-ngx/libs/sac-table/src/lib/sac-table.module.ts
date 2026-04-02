/**
 * SAC Table Module
 *
 * Angular module for SAC Table/Grid components.
 * Selector: sac-table (from mangle/sac_widget.mg)
 */

import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';

import { SacTableComponent } from './components/sac-table.component';

@NgModule({
  imports: [CommonModule],
  declarations: [SacTableComponent],
  exports: [SacTableComponent],
})
export class SacTableModule {}
