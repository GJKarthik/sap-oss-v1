import {
  ChangeDetectorRef,
  Component,
  ElementRef,
  EventEmitter,
  Input as InputDecorator,
  NgZone,
  booleanAttribute,
  inject,
} from '@angular/core';
import { GenericControlValueAccessor } from '@ui5/webcomponents-ngx/generic-cva';
import { ProxyInputs, ProxyOutputs } from '@ui5/webcomponents-ngx/utils';
import '@ui5/webcomponents/dist/FileUploader.js';
import {
  default as FileUploader,
  FileUploaderChangeEventDetail,
  FileUploaderFileSizeExceedEventDetail,
} from '@ui5/webcomponents/dist/FileUploader.js';
@ProxyInputs([
  'accept',
  'hideInput',
  'disabled',
  'multiple',
  'name',
  'placeholder',
  'value',
  'maxFileSize',
  'valueState',
  'required',
  'accessibleName',
  'accessibleNameRef',
  'accessibleDescription',
  'accessibleDescriptionRef',
])
@ProxyOutputs(['change: ui5Change', 'file-size-exceed: ui5FileSizeExceed'])
@Component({
  standalone: true,
  selector: 'ui5-file-uploader',
  template: '<ng-content></ng-content>',
  inputs: [
    'accept',
    'hideInput',
    'disabled',
    'multiple',
    'name',
    'placeholder',
    'value',
    'maxFileSize',
    'valueState',
    'required',
    'accessibleName',
    'accessibleNameRef',
    'accessibleDescription',
    'accessibleDescriptionRef',
  ],
  outputs: ['ui5Change', 'ui5FileSizeExceed'],
  exportAs: 'ui5FileUploader',
  hostDirectives: [GenericControlValueAccessor],
  host: { '(change)': '_cva?.onChange?.(cvaValue);' },
})
class FileUploaderComponent {
  /**
        Comma-separated list of file types that the component should accept.

**Note:** Please make sure you are adding the `.` in front on the file type, e.g. `.png` in case you want to accept png's only.
        */
  accept!: string | undefined;
  /**
        If set to "true", the input field of component will not be rendered. Only the default slot that is passed will be rendered.

**Note:** Use this property in combination with the default slot to achieve a button-only file uploader design.
        */
  @InputDecorator({ transform: booleanAttribute })
  hideInput!: boolean;
  /**
        Defines whether the component is in disabled state.

**Note:** A disabled component is completely noninteractive.
        */
  @InputDecorator({ transform: booleanAttribute })
  disabled!: boolean;
  /**
        Allows multiple files to be chosen.
        */
  @InputDecorator({ transform: booleanAttribute })
  multiple!: boolean;
  /**
        Determines the name by which the component will be identified upon submission in an HTML form.

**Note:** This property is only applicable within the context of an HTML Form element.
        */
  name!: string | undefined;
  /**
        Defines a short hint intended to aid the user with data entry when the component has no value.
        */
  placeholder!: string | undefined;
  /**
        Defines the name/names of the file/files to upload.
        */
  value!: string;
  /**
        Defines the maximum file size in megabytes which prevents the upload if at least one file exceeds it.
        */
  maxFileSize!: number | undefined;
  /**
        Defines the value state of the component.
        */
  valueState!: 'None' | 'Positive' | 'Critical' | 'Negative' | 'Information';
  /**
        Defines whether the component is required.
        */
  @InputDecorator({ transform: booleanAttribute })
  required!: boolean;
  /**
        Defines the accessible ARIA name of the component.
        */
  accessibleName!: string | undefined;
  /**
        Receives id(or many ids) of the elements that label the input.
        */
  accessibleNameRef!: string | undefined;
  /**
        Defines the accessible description of the component.
        */
  accessibleDescription!: string | undefined;
  /**
        Receives id(or many ids) of the elements that describe the input.
        */
  accessibleDescriptionRef!: string | undefined;

  /**
     Event is fired when the value of the file path has been changed.

**Note:** Keep in mind that because of the HTML input element of type file, the event is also fired in Chrome browser when the Cancel button of the uploads window is pressed.
    */
  ui5Change!: EventEmitter<FileUploaderChangeEventDetail>;
  /**
     Event is fired when the size of a file is above the `maxFileSize` property value.
    */
  ui5FileSizeExceed!: EventEmitter<FileUploaderFileSizeExceedEventDetail>;

  private elementRef: ElementRef<FileUploader> = inject(ElementRef);
  private zone = inject(NgZone);
  private cdr = inject(ChangeDetectorRef);
  protected _cva = inject(GenericControlValueAccessor);

  get element(): FileUploader {
    return this.elementRef.nativeElement;
  }

  set cvaValue(val) {
    this.element.value = val;
    this.cdr.detectChanges();
  }
  get cvaValue() {
    return this.element.value;
  }

  constructor() {
    this.cdr.detach();
    this._cva.host = this;
  }
}
export { FileUploaderComponent };
