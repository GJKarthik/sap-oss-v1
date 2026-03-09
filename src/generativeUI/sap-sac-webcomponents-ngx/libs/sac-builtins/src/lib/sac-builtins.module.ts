/**
 * SAC Builtins Module
 *
 * Angular module for built-in utility services: NucleusConsole, NucleusDate,
 * NucleusJSON, NucleusMath, Timer, TextPool, SearchToInsight.
 * No components — service-only module.
 */

import { NgModule } from '@angular/core';

import { NucleusConsoleService } from './services/nucleus-console.service';
import { NucleusDateService } from './services/nucleus-date.service';
import { NucleusJsonService } from './services/nucleus-json.service';
import { NucleusMathService } from './services/nucleus-math.service';
import { NucleusTimerService } from './services/nucleus-timer.service';
import { NucleusTextPoolService } from './services/nucleus-textpool.service';
import { SearchToInsightService } from './services/search-to-insight.service';

@NgModule({
  providers: [
    NucleusConsoleService,
    NucleusDateService,
    NucleusJsonService,
    NucleusMathService,
    NucleusTimerService,
    NucleusTextPoolService,
    SearchToInsightService,
  ],
})
export class SacBuiltinsModule {}
