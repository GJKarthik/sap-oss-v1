// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
import {Inject, NgModule} from '@angular/core';
import {setAnimationMode} from '@ui5/webcomponents-base/dist/config/AnimationMode.js';

interface Ui5Config {
  animationMode: string;
}

const setters: Record<keyof Ui5Config, (val: any) => void> = {
  animationMode: setAnimationMode,
};

@NgModule({})
export class Ui5WebcomponentsConfigModule {
  constructor(@Inject('rootConfig') _config: Ui5Config) {
    // Configuration is applied via the forRoot() factory; no runtime action needed here.
  }

  static forRoot(config: Partial<Ui5Config>) {
    return {
      ngModule: Ui5WebcomponentsConfigModule,
      providers: [
        {
          provide: 'rootConfig',
          useFactory: () => {
            Object.entries(config).filter(([, val]) => val !== undefined).forEach(([key, val]) => {
              setters[key](val);
            });
            return config;
          }
        }
      ]
    };
  }
}
