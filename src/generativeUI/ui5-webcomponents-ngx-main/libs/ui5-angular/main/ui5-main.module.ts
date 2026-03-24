import { NgModule } from "@angular/core";
import { Ui5WebcomponentsMainThemingService } from "@ui5/webcomponents-ngx/main/theming";
import "@ui5/webcomponents/dist/Assets.js";
import { AvatarComponent } from "@ui5/webcomponents-ngx/main/avatar";
import { AvatarGroupComponent } from "@ui5/webcomponents-ngx/main/avatar-group";
import { BarComponent } from "@ui5/webcomponents-ngx/main/bar";
import { BreadcrumbsComponent } from "@ui5/webcomponents-ngx/main/breadcrumbs";
import { BreadcrumbsItemComponent } from "@ui5/webcomponents-ngx/main/breadcrumbs-item";
import { BusyIndicatorComponent } from "@ui5/webcomponents-ngx/main/busy-indicator";
import { ButtonComponent } from "@ui5/webcomponents-ngx/main/button";
import { ButtonBadgeComponent } from "@ui5/webcomponents-ngx/main/button-badge";
import { CalendarComponent } from "@ui5/webcomponents-ngx/main/calendar";
import { CalendarDateComponent } from "@ui5/webcomponents-ngx/main/calendar-date";
import { CalendarDateRangeComponent } from "@ui5/webcomponents-ngx/main/calendar-date-range";
import { CalendarLegendComponent } from "@ui5/webcomponents-ngx/main/calendar-legend";
import { CalendarLegendItemComponent } from "@ui5/webcomponents-ngx/main/calendar-legend-item";
import { CardComponent } from "@ui5/webcomponents-ngx/main/card";
import { CardHeaderComponent } from "@ui5/webcomponents-ngx/main/card-header";
import { CarouselComponent } from "@ui5/webcomponents-ngx/main/carousel";
import { CheckBoxComponent } from "@ui5/webcomponents-ngx/main/check-box";
import { ColorPaletteComponent } from "@ui5/webcomponents-ngx/main/color-palette";
import { ColorPaletteItemComponent } from "@ui5/webcomponents-ngx/main/color-palette-item";
import { ColorPalettePopoverComponent } from "@ui5/webcomponents-ngx/main/color-palette-popover";
import { ColorPickerComponent } from "@ui5/webcomponents-ngx/main/color-picker";
import { ComboBoxComponent } from "@ui5/webcomponents-ngx/main/combo-box";
import { ComboBoxItemComponent } from "@ui5/webcomponents-ngx/main/combo-box-item";
import { ComboBoxItemGroupComponent } from "@ui5/webcomponents-ngx/main/combo-box-item-group";
import { DatePickerComponent } from "@ui5/webcomponents-ngx/main/date-picker";
import { DateRangePickerComponent } from "@ui5/webcomponents-ngx/main/date-range-picker";
import { DateTimePickerComponent } from "@ui5/webcomponents-ngx/main/date-time-picker";
import { DialogComponent } from "@ui5/webcomponents-ngx/main/dialog";
import { DynamicDateRangeComponent } from "@ui5/webcomponents-ngx/main/dynamic-date-range";
import { ExpandableTextComponent } from "@ui5/webcomponents-ngx/main/expandable-text";
import { FileUploaderComponent } from "@ui5/webcomponents-ngx/main/file-uploader";
import { FormComponent } from "@ui5/webcomponents-ngx/main/form";
import { FormGroupComponent } from "@ui5/webcomponents-ngx/main/form-group";
import { FormItemComponent } from "@ui5/webcomponents-ngx/main/form-item";
import { IconComponent } from "@ui5/webcomponents-ngx/main/icon";
import { InputComponent } from "@ui5/webcomponents-ngx/main/input";
import { LabelComponent } from "@ui5/webcomponents-ngx/main/label";
import { LinkComponent } from "@ui5/webcomponents-ngx/main/link";
import { ListComponent } from "@ui5/webcomponents-ngx/main/list";
import { ListItemCustomComponent } from "@ui5/webcomponents-ngx/main/list-item-custom";
import { ListItemGroupComponent } from "@ui5/webcomponents-ngx/main/list-item-group";
import { ListItemStandardComponent } from "@ui5/webcomponents-ngx/main/list-item-standard";
import { MenuComponent } from "@ui5/webcomponents-ngx/main/menu";
import { MenuItemComponent } from "@ui5/webcomponents-ngx/main/menu-item";
import { MenuItemGroupComponent } from "@ui5/webcomponents-ngx/main/menu-item-group";
import { MenuSeparatorComponent } from "@ui5/webcomponents-ngx/main/menu-separator";
import { MessageStripComponent } from "@ui5/webcomponents-ngx/main/message-strip";
import { MultiComboBoxComponent } from "@ui5/webcomponents-ngx/main/multi-combo-box";
import { MultiComboBoxItemComponent } from "@ui5/webcomponents-ngx/main/multi-combo-box-item";
import { MultiComboBoxItemGroupComponent } from "@ui5/webcomponents-ngx/main/multi-combo-box-item-group";
import { MultiInputComponent } from "@ui5/webcomponents-ngx/main/multi-input";
import { OptionComponent } from "@ui5/webcomponents-ngx/main/option";
import { OptionCustomComponent } from "@ui5/webcomponents-ngx/main/option-custom";
import { PanelComponent } from "@ui5/webcomponents-ngx/main/panel";
import { PopoverComponent } from "@ui5/webcomponents-ngx/main/popover";
import { ProgressIndicatorComponent } from "@ui5/webcomponents-ngx/main/progress-indicator";
import { RadioButtonComponent } from "@ui5/webcomponents-ngx/main/radio-button";
import { RangeSliderComponent } from "@ui5/webcomponents-ngx/main/range-slider";
import { RatingIndicatorComponent } from "@ui5/webcomponents-ngx/main/rating-indicator";
import { ResponsivePopoverComponent } from "@ui5/webcomponents-ngx/main/responsive-popover";
import { SegmentedButtonComponent } from "@ui5/webcomponents-ngx/main/segmented-button";
import { SegmentedButtonItemComponent } from "@ui5/webcomponents-ngx/main/segmented-button-item";
import { SelectComponent } from "@ui5/webcomponents-ngx/main/select";
import { SliderComponent } from "@ui5/webcomponents-ngx/main/slider";
import { SpecialCalendarDateComponent } from "@ui5/webcomponents-ngx/main/special-calendar-date";
import { SplitButtonComponent } from "@ui5/webcomponents-ngx/main/split-button";
import { StepInputComponent } from "@ui5/webcomponents-ngx/main/step-input";
import { SuggestionItemComponent } from "@ui5/webcomponents-ngx/main/suggestion-item";
import { SuggestionItemCustomComponent } from "@ui5/webcomponents-ngx/main/suggestion-item-custom";
import { SuggestionItemGroupComponent } from "@ui5/webcomponents-ngx/main/suggestion-item-group";
import { SwitchComponent } from "@ui5/webcomponents-ngx/main/switch";
import { TabComponent } from "@ui5/webcomponents-ngx/main/tab";
import { TabContainerComponent } from "@ui5/webcomponents-ngx/main/tab-container";
import { TabSeparatorComponent } from "@ui5/webcomponents-ngx/main/tab-separator";
import { TableComponent } from "@ui5/webcomponents-ngx/main/table";
import { TableCellComponent } from "@ui5/webcomponents-ngx/main/table-cell";
import { TableGrowingComponent } from "@ui5/webcomponents-ngx/main/table-growing";
import { TableHeaderCellComponent } from "@ui5/webcomponents-ngx/main/table-header-cell";
import { TableHeaderCellActionAIComponent } from "@ui5/webcomponents-ngx/main/table-header-cell-action-ai";
import { TableHeaderRowComponent } from "@ui5/webcomponents-ngx/main/table-header-row";
import { TableRowComponent } from "@ui5/webcomponents-ngx/main/table-row";
import { TableRowActionComponent } from "@ui5/webcomponents-ngx/main/table-row-action";
import { TableRowActionNavigationComponent } from "@ui5/webcomponents-ngx/main/table-row-action-navigation";
import { TableSelectionComponent } from "@ui5/webcomponents-ngx/main/table-selection";
import { TableSelectionMultiComponent } from "@ui5/webcomponents-ngx/main/table-selection-multi";
import { TableSelectionSingleComponent } from "@ui5/webcomponents-ngx/main/table-selection-single";
import { TableVirtualizerComponent } from "@ui5/webcomponents-ngx/main/table-virtualizer";
import { TagComponent } from "@ui5/webcomponents-ngx/main/tag";
import { TextComponent } from "@ui5/webcomponents-ngx/main/text";
import { TextAreaComponent } from "@ui5/webcomponents-ngx/main/text-area";
import { TimePickerComponent } from "@ui5/webcomponents-ngx/main/time-picker";
import { TitleComponent } from "@ui5/webcomponents-ngx/main/title";
import { ToastComponent } from "@ui5/webcomponents-ngx/main/toast";
import { ToggleButtonComponent } from "@ui5/webcomponents-ngx/main/toggle-button";
import { TokenComponent } from "@ui5/webcomponents-ngx/main/token";
import { TokenizerComponent } from "@ui5/webcomponents-ngx/main/tokenizer";
import { ToolbarComponent } from "@ui5/webcomponents-ngx/main/toolbar";
import { ToolbarButtonComponent } from "@ui5/webcomponents-ngx/main/toolbar-button";
import { ToolbarSelectComponent } from "@ui5/webcomponents-ngx/main/toolbar-select";
import { ToolbarSelectOptionComponent } from "@ui5/webcomponents-ngx/main/toolbar-select-option";
import { ToolbarSeparatorComponent } from "@ui5/webcomponents-ngx/main/toolbar-separator";
import { ToolbarSpacerComponent } from "@ui5/webcomponents-ngx/main/toolbar-spacer";
import { TreeComponent } from "@ui5/webcomponents-ngx/main/tree";
import { TreeItemComponent } from "@ui5/webcomponents-ngx/main/tree-item";
import { TreeItemCustomComponent } from "@ui5/webcomponents-ngx/main/tree-item-custom";

const imports = [
  AvatarComponent,
  AvatarGroupComponent,
  BarComponent,
  BreadcrumbsComponent,
  BreadcrumbsItemComponent,
  BusyIndicatorComponent,
  ButtonComponent,
  ButtonBadgeComponent,
  CalendarComponent,
  CalendarDateComponent,
  CalendarDateRangeComponent,
  CalendarLegendComponent,
  CalendarLegendItemComponent,
  CardComponent,
  CardHeaderComponent,
  CarouselComponent,
  CheckBoxComponent,
  ColorPaletteComponent,
  ColorPaletteItemComponent,
  ColorPalettePopoverComponent,
  ColorPickerComponent,
  ComboBoxComponent,
  ComboBoxItemComponent,
  ComboBoxItemGroupComponent,
  DatePickerComponent,
  DateRangePickerComponent,
  DateTimePickerComponent,
  DialogComponent,
  DynamicDateRangeComponent,
  ExpandableTextComponent,
  FileUploaderComponent,
  FormComponent,
  FormGroupComponent,
  FormItemComponent,
  IconComponent,
  InputComponent,
  LabelComponent,
  LinkComponent,
  ListComponent,
  ListItemCustomComponent,
  ListItemGroupComponent,
  ListItemStandardComponent,
  MenuComponent,
  MenuItemComponent,
  MenuItemGroupComponent,
  MenuSeparatorComponent,
  MessageStripComponent,
  MultiComboBoxComponent,
  MultiComboBoxItemComponent,
  MultiComboBoxItemGroupComponent,
  MultiInputComponent,
  OptionComponent,
  OptionCustomComponent,
  PanelComponent,
  PopoverComponent,
  ProgressIndicatorComponent,
  RadioButtonComponent,
  RangeSliderComponent,
  RatingIndicatorComponent,
  ResponsivePopoverComponent,
  SegmentedButtonComponent,
  SegmentedButtonItemComponent,
  SelectComponent,
  SliderComponent,
  SpecialCalendarDateComponent,
  SplitButtonComponent,
  StepInputComponent,
  SuggestionItemComponent,
  SuggestionItemCustomComponent,
  SuggestionItemGroupComponent,
  SwitchComponent,
  TabComponent,
  TabContainerComponent,
  TabSeparatorComponent,
  TableComponent,
  TableCellComponent,
  TableGrowingComponent,
  TableHeaderCellComponent,
  TableHeaderCellActionAIComponent,
  TableHeaderRowComponent,
  TableRowComponent,
  TableRowActionComponent,
  TableRowActionNavigationComponent,
  TableSelectionComponent,
  TableSelectionMultiComponent,
  TableSelectionSingleComponent,
  TableVirtualizerComponent,
  TagComponent,
  TextComponent,
  TextAreaComponent,
  TimePickerComponent,
  TitleComponent,
  ToastComponent,
  ToggleButtonComponent,
  TokenComponent,
  TokenizerComponent,
  ToolbarComponent,
  ToolbarButtonComponent,
  ToolbarSelectComponent,
  ToolbarSelectOptionComponent,
  ToolbarSeparatorComponent,
  ToolbarSpacerComponent,
  TreeComponent,
  TreeItemComponent,
  TreeItemCustomComponent,
];
const exports = [...imports];

@NgModule({
  imports: [...imports],
  exports: [...exports],
})
class Ui5MainModule {
  constructor(
    ui5WebcomponentsMainThemingService: Ui5WebcomponentsMainThemingService,
  ) {}
}
export { Ui5MainModule };
