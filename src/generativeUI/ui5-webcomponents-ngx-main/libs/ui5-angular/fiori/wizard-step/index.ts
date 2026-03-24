import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import '@ui5/webcomponents-fiori/dist/WizardStep.js';
import WizardStep from '@ui5/webcomponents-fiori/dist/WizardStep.js';
import { ProxyInputs } from '@ui5/webcomponents-ngx/utils';
@ProxyInputs([
  'titleText',
  'subtitleText',
  'icon',
  'disabled',
  'selected',
  'branching',
])
@Component({
  standalone: true,
  selector: 'ui5-wizard-step',
  template: '<ng-content></ng-content>',
  inputs: [
    'titleText',
    'subtitleText',
    'icon',
    'disabled',
    'selected',
    'branching',
  ],
  exportAs: 'ui5WizardStep',
})
class WizardStepComponent {
  /**
        Defines the `titleText` of the step.

**Note:** The text is displayed in the `ui5-wizard` navigation header.
        */
  titleText!: string | undefined;
  /**
        Defines the `subtitleText` of the step.

**Note:** the text is displayed in the `ui5-wizard` navigation header.
        */
  subtitleText!: string | undefined;
  /**
        Defines the `icon` of the step.

**Note:** The icon is displayed in the `ui5-wizard` navigation header.

The SAP-icons font provides numerous options.
See all the available icons in the [Icon Explorer](https://sdk.openui5.org/test-resources/sap/m/demokit/iconExplorer/webapp/index.html).
        */
  icon!: string | undefined;
  /**
        Defines if the step is `disabled`. When disabled the step is displayed,
but the user can't select the step by clicking or navigate to it with scrolling.

**Note:** Step can't be `selected` and `disabled` at the same time.
In this case the `selected` property would take precedence.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Defines the step's `selected` state - the step that is currently active.

**Note:** Step can't be `selected` and `disabled` at the same time.
In this case the `selected` property would take precedence.
        */
  @InputDecorator({ transform: booleanAttribute })
  selected!: boolean;
  /**
        When `branching` is enabled a dashed line would be displayed after the step,
meant to indicate that the next step is not yet known and depends on user choice in the current step.

**Note:** It is recommended to use `branching` on the last known step
and later add new steps when it becomes clear how the wizard flow should continue.
        */
  @InputDecorator({ transform: booleanAttribute })
  branching!: boolean;

  private elementRef: ElementRef<WizardStep> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);

  get element(): WizardStep {
    return this.elementRef.nativeElement;
  }

  constructor() {
    this.cdr.detach();
  }
}
export { WizardStepComponent };
