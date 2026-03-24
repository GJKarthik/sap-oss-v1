import { NgModule } from "@angular/core";
import { ActionBarDirective } from "@fundamental-styles/theming-ngx/directives/action-bar";
import { ActionSheetDirective } from "@fundamental-styles/theming-ngx/directives/action-sheet";
import { AiBusyIndicatorDirective } from "@fundamental-styles/theming-ngx/directives/ai-busy-indicator";
import { AiLoadingBarDirective } from "@fundamental-styles/theming-ngx/directives/ai-loading-bar";
import { AiTextDirective } from "@fundamental-styles/theming-ngx/directives/ai-text";
import { AiWritingAssistantVersioningDirective } from "@fundamental-styles/theming-ngx/directives/ai-writing-assistant-versioning";
import { AiWritingAssistantDirective } from "@fundamental-styles/theming-ngx/directives/ai-writing-assistant";
import { AlertDirective } from "@fundamental-styles/theming-ngx/directives/alert";
import { AvatarGroupDirective } from "@fundamental-styles/theming-ngx/directives/avatar-group";
import { AvatarDirective } from "@fundamental-styles/theming-ngx/directives/avatar";
import { BadgeDirective } from "@fundamental-styles/theming-ngx/directives/badge";
import { BarDirective } from "@fundamental-styles/theming-ngx/directives/bar";
import { BreadcrumbDirective } from "@fundamental-styles/theming-ngx/directives/breadcrumb";
import { BusyIndicatorDirective } from "@fundamental-styles/theming-ngx/directives/busy-indicator";
import { ButtonSplitDirective } from "@fundamental-styles/theming-ngx/directives/button-split";
import { ButtonDirective } from "@fundamental-styles/theming-ngx/directives/button";
import { CalendarDirective } from "@fundamental-styles/theming-ngx/directives/calendar";
import { CardDirective } from "@fundamental-styles/theming-ngx/directives/card";
import { CarouselDirective } from "@fundamental-styles/theming-ngx/directives/carousel";
import { CheckboxDirective } from "@fundamental-styles/theming-ngx/directives/checkbox";
import { CodeDirective } from "@fundamental-styles/theming-ngx/directives/code";
import { CounterDirective } from "@fundamental-styles/theming-ngx/directives/counter";
import { DialogDirective } from "@fundamental-styles/theming-ngx/directives/dialog";
import { DynamicPageDirective } from "@fundamental-styles/theming-ngx/directives/dynamic-page";
import { DynamicSideContentDirective } from "@fundamental-styles/theming-ngx/directives/dynamic-side-content";
import { FacetDirective } from "@fundamental-styles/theming-ngx/directives/facet";
import { FeedInputDirective } from "@fundamental-styles/theming-ngx/directives/feed-input";
import { FeedListDirective } from "@fundamental-styles/theming-ngx/directives/feed-list";
import { FieldsetDirective } from "@fundamental-styles/theming-ngx/directives/fieldset";
import { FileUploaderDirective } from "@fundamental-styles/theming-ngx/directives/file-uploader";
import { FixedCardLayoutDirective } from "@fundamental-styles/theming-ngx/directives/fixed-card-layout";
import { FlexibleColumnLayoutDirective } from "@fundamental-styles/theming-ngx/directives/flexible-column-layout";
import { FormGroupDirective } from "@fundamental-styles/theming-ngx/directives/form-group";
import { FormHeaderDirective } from "@fundamental-styles/theming-ngx/directives/form-header";
import { FormItemDirective } from "@fundamental-styles/theming-ngx/directives/form-item";
import { FormLabelDirective } from "@fundamental-styles/theming-ngx/directives/form-label";
import { FormLayoutGridDirective } from "@fundamental-styles/theming-ngx/directives/form-layout-grid";
import { FormMessageDirective } from "@fundamental-styles/theming-ngx/directives/form-message";
import { FundamentalStylesDirective } from "@fundamental-styles/theming-ngx/directives/fundamental-styles";
import { GenericTagDirective } from "@fundamental-styles/theming-ngx/directives/generic-tag";
import { GridListDirective } from "@fundamental-styles/theming-ngx/directives/grid-list";
import { HelpersDirective } from "@fundamental-styles/theming-ngx/directives/helpers";
import { HorizontalNavigationDirective } from "@fundamental-styles/theming-ngx/directives/horizontal-navigation";
import { IconTabBarDirective } from "@fundamental-styles/theming-ngx/directives/icon-tab-bar";
import { IconDirective } from "@fundamental-styles/theming-ngx/directives/icon";
import { IllustratedMessageDirective } from "@fundamental-styles/theming-ngx/directives/illustrated-message";
import { InfoLabelDirective } from "@fundamental-styles/theming-ngx/directives/info-label";
import { InputGroupDirective } from "@fundamental-styles/theming-ngx/directives/input-group";
import { InputDirective } from "@fundamental-styles/theming-ngx/directives/input";
import { LayoutGridDirective } from "@fundamental-styles/theming-ngx/directives/layout-grid";
import { LayoutPanelDirective } from "@fundamental-styles/theming-ngx/directives/layout-panel";
import { LayoutDirective } from "@fundamental-styles/theming-ngx/directives/layout";
import { LinkDirective } from "@fundamental-styles/theming-ngx/directives/link";
import { ListDirective } from "@fundamental-styles/theming-ngx/directives/list";
import { MarginsDirective } from "@fundamental-styles/theming-ngx/directives/margins";
import { MenuDirective } from "@fundamental-styles/theming-ngx/directives/menu";
import { MessageBoxDirective } from "@fundamental-styles/theming-ngx/directives/message-box";
import { MessagePageDirective } from "@fundamental-styles/theming-ngx/directives/message-page";
import { MessagePopoverDirective } from "@fundamental-styles/theming-ngx/directives/message-popover";
import { MessageStripDirective } from "@fundamental-styles/theming-ngx/directives/message-strip";
import { MessageToastDirective } from "@fundamental-styles/theming-ngx/directives/message-toast";
import { MicroProcessFlowDirective } from "@fundamental-styles/theming-ngx/directives/micro-process-flow";
import { NavigationListDirective } from "@fundamental-styles/theming-ngx/directives/navigation-list";
import { NavigationMenuDirective } from "@fundamental-styles/theming-ngx/directives/navigation-menu";
import { NavigationDirective } from "@fundamental-styles/theming-ngx/directives/navigation";
import { NotificationDirective } from "@fundamental-styles/theming-ngx/directives/notification";
import { NumericContentDirective } from "@fundamental-styles/theming-ngx/directives/numeric-content";
import { ObjectAttributeDirective } from "@fundamental-styles/theming-ngx/directives/object-attribute";
import { ObjectIdentifierDirective } from "@fundamental-styles/theming-ngx/directives/object-identifier";
import { ObjectListDirective } from "@fundamental-styles/theming-ngx/directives/object-list";
import { ObjectMarkerDirective } from "@fundamental-styles/theming-ngx/directives/object-marker";
import { ObjectNumberDirective } from "@fundamental-styles/theming-ngx/directives/object-number";
import { ObjectStatusDirective } from "@fundamental-styles/theming-ngx/directives/object-status";
import { OffScreenDirective } from "@fundamental-styles/theming-ngx/directives/off-screen";
import { PaddingsDirective } from "@fundamental-styles/theming-ngx/directives/paddings";
import { PageFooterDirective } from "@fundamental-styles/theming-ngx/directives/page-footer";
import { PageDirective } from "@fundamental-styles/theming-ngx/directives/page";
import { PaginationDirective } from "@fundamental-styles/theming-ngx/directives/pagination";
import { PanelDirective } from "@fundamental-styles/theming-ngx/directives/panel";
import { PopoverDirective } from "@fundamental-styles/theming-ngx/directives/popover";
import { ProductSwitchDirective } from "@fundamental-styles/theming-ngx/directives/product-switch";
import { ProgressIndicatorDirective } from "@fundamental-styles/theming-ngx/directives/progress-indicator";
import { PromptInputDirective } from "@fundamental-styles/theming-ngx/directives/prompt-input";
import { QuickViewDirective } from "@fundamental-styles/theming-ngx/directives/quick-view";
import { RadioDirective } from "@fundamental-styles/theming-ngx/directives/radio";
import { RatingIndicatorDirective } from "@fundamental-styles/theming-ngx/directives/rating-indicator";
import { ResizableCardLayoutDirective } from "@fundamental-styles/theming-ngx/directives/resizable-card-layout";
import { ScrollbarDirective } from "@fundamental-styles/theming-ngx/directives/scrollbar";
import { SearchFieldDirective } from "@fundamental-styles/theming-ngx/directives/search-field";
import { SectionDirective } from "@fundamental-styles/theming-ngx/directives/section";
import { SegmentedButtonDirective } from "@fundamental-styles/theming-ngx/directives/segmented-button";
import { SelectDirective } from "@fundamental-styles/theming-ngx/directives/select";
import { SettingsDirective } from "@fundamental-styles/theming-ngx/directives/settings";
import { ShellbarDirective } from "@fundamental-styles/theming-ngx/directives/shellbar";
import { SideNavDirective } from "@fundamental-styles/theming-ngx/directives/side-nav";
import { SkeletonDirective } from "@fundamental-styles/theming-ngx/directives/skeleton";
import { SliderDirective } from "@fundamental-styles/theming-ngx/directives/slider";
import { SplitterDirective } from "@fundamental-styles/theming-ngx/directives/splitter";
import { StatusIndicatorDirective } from "@fundamental-styles/theming-ngx/directives/status-indicator";
import { StepInputDirective } from "@fundamental-styles/theming-ngx/directives/step-input";
import { SwitchDirective } from "@fundamental-styles/theming-ngx/directives/switch";
import { TableDirective } from "@fundamental-styles/theming-ngx/directives/table";
import { TabsDirective } from "@fundamental-styles/theming-ngx/directives/tabs";
import { TextDirective } from "@fundamental-styles/theming-ngx/directives/text";
import { TextareaDirective } from "@fundamental-styles/theming-ngx/directives/textarea";
import { TileDirective } from "@fundamental-styles/theming-ngx/directives/tile";
import { TimeDirective } from "@fundamental-styles/theming-ngx/directives/time";
import { TimepickerDirective } from "@fundamental-styles/theming-ngx/directives/timepicker";
import { TitleBarDirective } from "@fundamental-styles/theming-ngx/directives/title-bar";
import { TitleDirective } from "@fundamental-styles/theming-ngx/directives/title";
import { TokenDirective } from "@fundamental-styles/theming-ngx/directives/token";
import { TokenizerDirective } from "@fundamental-styles/theming-ngx/directives/tokenizer";
import { ToolHeaderDirective } from "@fundamental-styles/theming-ngx/directives/tool-header";
import { ToolLayoutDirective } from "@fundamental-styles/theming-ngx/directives/tool-layout";
import { ToolbarDirective } from "@fundamental-styles/theming-ngx/directives/toolbar";
import { TreeDirective } from "@fundamental-styles/theming-ngx/directives/tree";
import { UploadCollectionDirective } from "@fundamental-styles/theming-ngx/directives/upload-collection";
import { UserMenuDirective } from "@fundamental-styles/theming-ngx/directives/user-menu";
import { VariantManagementDirective } from "@fundamental-styles/theming-ngx/directives/variant-management";
import { VerticalNavDirective } from "@fundamental-styles/theming-ngx/directives/vertical-nav";
import { WizardDirective } from "@fundamental-styles/theming-ngx/directives/wizard";

const imports = [
  ActionBarDirective,
  ActionSheetDirective,
  AiBusyIndicatorDirective,
  AiLoadingBarDirective,
  AiTextDirective,
  AiWritingAssistantVersioningDirective,
  AiWritingAssistantDirective,
  AlertDirective,
  AvatarGroupDirective,
  AvatarDirective,
  BadgeDirective,
  BarDirective,
  BreadcrumbDirective,
  BusyIndicatorDirective,
  ButtonSplitDirective,
  ButtonDirective,
  CalendarDirective,
  CardDirective,
  CarouselDirective,
  CheckboxDirective,
  CodeDirective,
  CounterDirective,
  DialogDirective,
  DynamicPageDirective,
  DynamicSideContentDirective,
  FacetDirective,
  FeedInputDirective,
  FeedListDirective,
  FieldsetDirective,
  FileUploaderDirective,
  FixedCardLayoutDirective,
  FlexibleColumnLayoutDirective,
  FormGroupDirective,
  FormHeaderDirective,
  FormItemDirective,
  FormLabelDirective,
  FormLayoutGridDirective,
  FormMessageDirective,
  FundamentalStylesDirective,
  GenericTagDirective,
  GridListDirective,
  HelpersDirective,
  HorizontalNavigationDirective,
  IconTabBarDirective,
  IconDirective,
  IllustratedMessageDirective,
  InfoLabelDirective,
  InputGroupDirective,
  InputDirective,
  LayoutGridDirective,
  LayoutPanelDirective,
  LayoutDirective,
  LinkDirective,
  ListDirective,
  MarginsDirective,
  MenuDirective,
  MessageBoxDirective,
  MessagePageDirective,
  MessagePopoverDirective,
  MessageStripDirective,
  MessageToastDirective,
  MicroProcessFlowDirective,
  NavigationListDirective,
  NavigationMenuDirective,
  NavigationDirective,
  NotificationDirective,
  NumericContentDirective,
  ObjectAttributeDirective,
  ObjectIdentifierDirective,
  ObjectListDirective,
  ObjectMarkerDirective,
  ObjectNumberDirective,
  ObjectStatusDirective,
  OffScreenDirective,
  PaddingsDirective,
  PageFooterDirective,
  PageDirective,
  PaginationDirective,
  PanelDirective,
  PopoverDirective,
  ProductSwitchDirective,
  ProgressIndicatorDirective,
  PromptInputDirective,
  QuickViewDirective,
  RadioDirective,
  RatingIndicatorDirective,
  ResizableCardLayoutDirective,
  ScrollbarDirective,
  SearchFieldDirective,
  SectionDirective,
  SegmentedButtonDirective,
  SelectDirective,
  SettingsDirective,
  ShellbarDirective,
  SideNavDirective,
  SkeletonDirective,
  SliderDirective,
  SplitterDirective,
  StatusIndicatorDirective,
  StepInputDirective,
  SwitchDirective,
  TableDirective,
  TabsDirective,
  TextDirective,
  TextareaDirective,
  TileDirective,
  TimeDirective,
  TimepickerDirective,
  TitleBarDirective,
  TitleDirective,
  TokenDirective,
  TokenizerDirective,
  ToolHeaderDirective,
  ToolLayoutDirective,
  ToolbarDirective,
  TreeDirective,
  UploadCollectionDirective,
  UserMenuDirective,
  VariantManagementDirective,
  VerticalNavDirective,
  WizardDirective,
];
const exports = [...imports];

@NgModule({
  imports: [...imports],
  exports: [...exports],
})
class FundamentalStylesComponentsModule {}
export { FundamentalStylesComponentsModule };
