import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  NgZone,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/Wizard.js';
import {
  default as Wizard,
  WizardStepChangeEventDetail,
} from '@ui5/webcomponents-fiori/dist/Wizard.js';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs(['contentLayout'])
@ProxyOutputs(['step-change: ui5StepChange'])
@Component({
  standalone: true,
  selector: 'ui5-wizard',
  template: '<ng-content></ng-content>',
  inputs: ['contentLayout'],
  outputs: ['ui5StepChange'],
  exportAs: 'ui5Wizard',
})
class WizardComponent {
  /**
        Defines how the content of the `ui5-wizard` would be visualized.
        */
  contentLayout!: 'MultipleSteps' | 'SingleStep';

  /**
     Fired when the step is changed by user interaction - either with scrolling,
or by clicking on the steps within the component header.
    */
  ui5StepChange!: EventEmitter<WizardStepChangeEventDetail>;

  private elementRef: ElementRef<Wizard> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): Wizard {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { WizardComponent };
