import { NgModule } from '@angular/core';
import { AvatarComponent } from '@ui5/webcomponents-ngx/main/avatar';
import { AvatarGroupComponent } from '@ui5/webcomponents-ngx/main/avatar-group';
import { BarComponent } from '@ui5/webcomponents-ngx/main/bar';
import { BusyIndicatorComponent } from '@ui5/webcomponents-ngx/main/busy-indicator';
import { ButtonComponent } from '@ui5/webcomponents-ngx/main/button';
import { CardComponent } from '@ui5/webcomponents-ngx/main/card';
import { CardHeaderComponent } from '@ui5/webcomponents-ngx/main/card-header';
import { CheckBoxComponent } from '@ui5/webcomponents-ngx/main/check-box';
import { DatePickerComponent } from '@ui5/webcomponents-ngx/main/date-picker';
import { DialogComponent } from '@ui5/webcomponents-ngx/main/dialog';
import { IconComponent } from '@ui5/webcomponents-ngx/main/icon';
import { InputComponent } from '@ui5/webcomponents-ngx/main/input';
import { LabelComponent } from '@ui5/webcomponents-ngx/main/label';
import { ListComponent } from '@ui5/webcomponents-ngx/main/list';
import { ListItemStandardComponent } from '@ui5/webcomponents-ngx/main/list-item-standard';
import { MessageStripComponent } from '@ui5/webcomponents-ngx/main/message-strip';
import { OptionComponent } from '@ui5/webcomponents-ngx/main/option';
import { PopoverComponent } from '@ui5/webcomponents-ngx/main/popover';
import { RadioButtonComponent } from '@ui5/webcomponents-ngx/main/radio-button';
import { SelectComponent } from '@ui5/webcomponents-ngx/main/select';
import { StepInputComponent } from '@ui5/webcomponents-ngx/main/step-input';
import { SwitchComponent } from '@ui5/webcomponents-ngx/main/switch';
import { TableComponent } from '@ui5/webcomponents-ngx/main/table';
import { TableCellComponent } from '@ui5/webcomponents-ngx/main/table-cell';
import { TableHeaderCellComponent } from '@ui5/webcomponents-ngx/main/table-header-cell';
import { TableHeaderRowComponent } from '@ui5/webcomponents-ngx/main/table-header-row';
import { TableRowComponent } from '@ui5/webcomponents-ngx/main/table-row';
import { TagComponent } from '@ui5/webcomponents-ngx/main/tag';
import { TextComponent } from '@ui5/webcomponents-ngx/main/text';
import { TextAreaComponent } from '@ui5/webcomponents-ngx/main/text-area';
import { TitleComponent } from '@ui5/webcomponents-ngx/main/title';
import { IllustratedMessageComponent } from '@ui5/webcomponents-ngx/fiori/illustrated-message';
import { PageComponent } from '@ui5/webcomponents-ngx/fiori/page';
import { ShellBarComponent } from '@ui5/webcomponents-ngx/fiori/shell-bar';
import { SideNavigationComponent } from '@ui5/webcomponents-ngx/fiori/side-navigation';
import { SideNavigationItemComponent } from '@ui5/webcomponents-ngx/fiori/side-navigation-item';

const imports = [
  AvatarComponent,
  AvatarGroupComponent,
  BarComponent,
  BusyIndicatorComponent,
  ButtonComponent,
  CardComponent,
  CardHeaderComponent,
  CheckBoxComponent,
  DatePickerComponent,
  DialogComponent,
  IconComponent,
  IllustratedMessageComponent,
  InputComponent,
  LabelComponent,
  ListComponent,
  ListItemStandardComponent,
  MessageStripComponent,
  OptionComponent,
  PageComponent,
  PopoverComponent,
  RadioButtonComponent,
  SelectComponent,
  ShellBarComponent,
  SideNavigationComponent,
  SideNavigationItemComponent,
  StepInputComponent,
  SwitchComponent,
  TableComponent,
  TableCellComponent,
  TableHeaderCellComponent,
  TableHeaderRowComponent,
  TableRowComponent,
  TagComponent,
  TextComponent,
  TextAreaComponent,
  TitleComponent,
];

@NgModule({
  imports: [...imports],
  exports: [...imports],
})
export class Ui5WorkspaceComponentsModule {}
