import { NgModule } from '@angular/core';
// Main components
import { AvatarComponent } from '@ui5/webcomponents-ngx/main/avatar';
import { AvatarGroupComponent } from '@ui5/webcomponents-ngx/main/avatar-group';
import { BarComponent } from '@ui5/webcomponents-ngx/main/bar';
import { BreadcrumbsComponent } from '@ui5/webcomponents-ngx/main/breadcrumbs';
import { BreadcrumbsItemComponent } from '@ui5/webcomponents-ngx/main/breadcrumbs-item';
import { BusyIndicatorComponent } from '@ui5/webcomponents-ngx/main/busy-indicator';
import { ButtonComponent } from '@ui5/webcomponents-ngx/main/button';
import { CardComponent } from '@ui5/webcomponents-ngx/main/card';
import { CardHeaderComponent } from '@ui5/webcomponents-ngx/main/card-header';
import { CheckBoxComponent } from '@ui5/webcomponents-ngx/main/check-box';
import { DatePickerComponent } from '@ui5/webcomponents-ngx/main/date-picker';
import { DialogComponent } from '@ui5/webcomponents-ngx/main/dialog';
import { FileUploaderComponent } from '@ui5/webcomponents-ngx/main/file-uploader';
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
import { SplitButtonComponent } from '@ui5/webcomponents-ngx/main/split-button';
import { StepInputComponent } from '@ui5/webcomponents-ngx/main/step-input';
import { SwitchComponent } from '@ui5/webcomponents-ngx/main/switch';
import { TabContainerComponent } from '@ui5/webcomponents-ngx/main/tab-container';
import { TabComponent } from '@ui5/webcomponents-ngx/main/tab';
import { TableComponent } from '@ui5/webcomponents-ngx/main/table';
import { TableCellComponent } from '@ui5/webcomponents-ngx/main/table-cell';
import { TableHeaderCellComponent } from '@ui5/webcomponents-ngx/main/table-header-cell';
import { TableHeaderRowComponent } from '@ui5/webcomponents-ngx/main/table-header-row';
import { TableRowComponent } from '@ui5/webcomponents-ngx/main/table-row';
import { TagComponent } from '@ui5/webcomponents-ngx/main/tag';
import { TextComponent } from '@ui5/webcomponents-ngx/main/text';
import { TextAreaComponent } from '@ui5/webcomponents-ngx/main/text-area';
import { TitleComponent } from '@ui5/webcomponents-ngx/main/title';
// Fiori components
import { IllustratedMessageComponent } from '@ui5/webcomponents-ngx/fiori/illustrated-message';
import { NavigationLayoutComponent } from '@ui5/webcomponents-ngx/fiori/navigation-layout';
import { PageComponent } from '@ui5/webcomponents-ngx/fiori/page';
import { SearchComponent } from '@ui5/webcomponents-ngx/fiori/search';
import { ShellBarComponent } from '@ui5/webcomponents-ngx/fiori/shell-bar';
import { ShellBarItemComponent } from '@ui5/webcomponents-ngx/fiori/shell-bar-item';
import { ShellBarSearchComponent } from '@ui5/webcomponents-ngx/fiori/shell-bar-search';
import { ShellBarSpacerComponent } from '@ui5/webcomponents-ngx/fiori/shell-bar-spacer';
import { SideNavigationComponent } from '@ui5/webcomponents-ngx/fiori/side-navigation';
import { SideNavigationGroupComponent } from '@ui5/webcomponents-ngx/fiori/side-navigation-group';
import { SideNavigationItemComponent } from '@ui5/webcomponents-ngx/fiori/side-navigation-item';
import { UserMenuComponent } from '@ui5/webcomponents-ngx/fiori/user-menu';
import { UserMenuAccountComponent } from '@ui5/webcomponents-ngx/fiori/user-menu-account';
import { UserMenuItemComponent } from '@ui5/webcomponents-ngx/fiori/user-menu-item';

const imports = [
  // Main
  AvatarComponent,
  AvatarGroupComponent,
  BarComponent,
  BreadcrumbsComponent,
  BreadcrumbsItemComponent,
  BusyIndicatorComponent,
  ButtonComponent,
  CardComponent,
  CardHeaderComponent,
  CheckBoxComponent,
  DatePickerComponent,
  DialogComponent,
  FileUploaderComponent,
  IconComponent,
  InputComponent,
  LabelComponent,
  ListComponent,
  ListItemStandardComponent,
  MessageStripComponent,
  OptionComponent,
  PopoverComponent,
  RadioButtonComponent,
  SelectComponent,
  SplitButtonComponent,
  StepInputComponent,
  SwitchComponent,
  TabContainerComponent,
  TabComponent,
  TableComponent,
  TableCellComponent,
  TableHeaderCellComponent,
  TableHeaderRowComponent,
  TableRowComponent,
  TagComponent,
  TextComponent,
  TextAreaComponent,
  TitleComponent,
  // Fiori
  IllustratedMessageComponent,
  NavigationLayoutComponent,
  PageComponent,
  SearchComponent,
  ShellBarComponent,
  ShellBarItemComponent,
  ShellBarSearchComponent,
  ShellBarSpacerComponent,
  SideNavigationComponent,
  SideNavigationGroupComponent,
  SideNavigationItemComponent,
  UserMenuComponent,
  UserMenuAccountComponent,
  UserMenuItemComponent,
];

@NgModule({
  imports: [...imports],
  exports: [...imports],
})
export class Ui5WorkspaceComponentsModule {}
