import { NgModule } from '@angular/core';
import { AvatarComponent } from '@ui5/webcomponents-ngx/main/avatar';
import { BarComponent } from '@ui5/webcomponents-ngx/main/bar';
import { BusyIndicatorComponent } from '@ui5/webcomponents-ngx/main/busy-indicator';
import { ButtonComponent } from '@ui5/webcomponents-ngx/main/button';
import { CardComponent } from '@ui5/webcomponents-ngx/main/card';
import { CardHeaderComponent } from '@ui5/webcomponents-ngx/main/card-header';
import { DialogComponent } from '@ui5/webcomponents-ngx/main/dialog';
import { IconComponent } from '@ui5/webcomponents-ngx/main/icon';
import { InputComponent } from '@ui5/webcomponents-ngx/main/input';
import { LabelComponent } from '@ui5/webcomponents-ngx/main/label';
import { ListComponent } from '@ui5/webcomponents-ngx/main/list';
import { ListItemStandardComponent } from '@ui5/webcomponents-ngx/main/list-item-standard';
import { MenuComponent } from '@ui5/webcomponents-ngx/main/menu';
import { MenuItemComponent } from '@ui5/webcomponents-ngx/main/menu-item';
import { MessageStripComponent } from '@ui5/webcomponents-ngx/main/message-strip';
import { OptionComponent } from '@ui5/webcomponents-ngx/main/option';
import { PopoverComponent } from '@ui5/webcomponents-ngx/main/popover';
import { ProgressIndicatorComponent } from '@ui5/webcomponents-ngx/main/progress-indicator';
import { SelectComponent } from '@ui5/webcomponents-ngx/main/select';
import { StepInputComponent } from '@ui5/webcomponents-ngx/main/step-input';
import { SwitchComponent } from '@ui5/webcomponents-ngx/main/switch';
import { TabComponent } from '@ui5/webcomponents-ngx/main/tab';
import { TabContainerComponent } from '@ui5/webcomponents-ngx/main/tab-container';
import { TableComponent } from '@ui5/webcomponents-ngx/main/table';
import { TableCellComponent } from '@ui5/webcomponents-ngx/main/table-cell';
import { TableHeaderCellComponent } from '@ui5/webcomponents-ngx/main/table-header-cell';
import { TableRowComponent } from '@ui5/webcomponents-ngx/main/table-row';
import { TagComponent } from '@ui5/webcomponents-ngx/main/tag';
import { TextAreaComponent } from '@ui5/webcomponents-ngx/main/text-area';
import { TitleComponent } from '@ui5/webcomponents-ngx/main/title';
import { PageComponent } from '@ui5/webcomponents-ngx/fiori/page';
import { ShellBarComponent } from '@ui5/webcomponents-ngx/fiori/shell-bar';
import { ShellBarItemComponent } from '@ui5/webcomponents-ngx/fiori/shell-bar-item';

const imports = [
  AvatarComponent,
  BarComponent,
  BusyIndicatorComponent,
  ButtonComponent,
  CardComponent,
  CardHeaderComponent,
  DialogComponent,
  IconComponent,
  InputComponent,
  LabelComponent,
  ListComponent,
  ListItemStandardComponent,
  MenuComponent,
  MenuItemComponent,
  MessageStripComponent,
  OptionComponent,
  PageComponent,
  PopoverComponent,
  ProgressIndicatorComponent,
  SelectComponent,
  ShellBarComponent,
  ShellBarItemComponent,
  StepInputComponent,
  SwitchComponent,
  TabComponent,
  TabContainerComponent,
  TableComponent,
  TableCellComponent,
  TableHeaderCellComponent,
  TableRowComponent,
  TagComponent,
  TextAreaComponent,
  TitleComponent,
];

@NgModule({
  imports: [...imports],
  exports: [...imports],
})
export class Ui5TrainingComponentsModule {}
