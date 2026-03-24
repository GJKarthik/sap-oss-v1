import { NgModule } from "@angular/core";
import { Ui5WebcomponentsFioriThemingService } from "@ui5/webcomponents-ngx/fiori/theming";
import "@ui5/webcomponents-fiori/dist/Assets.js";
import { BarcodeScannerDialogComponent } from "@ui5/webcomponents-ngx/fiori/barcode-scanner-dialog";
import { DynamicPageComponent } from "@ui5/webcomponents-ngx/fiori/dynamic-page";
import { DynamicPageHeaderComponent } from "@ui5/webcomponents-ngx/fiori/dynamic-page-header";
import { DynamicPageTitleComponent } from "@ui5/webcomponents-ngx/fiori/dynamic-page-title";
import { DynamicSideContentComponent } from "@ui5/webcomponents-ngx/fiori/dynamic-side-content";
import { FilterItemComponent } from "@ui5/webcomponents-ngx/fiori/filter-item";
import { FilterItemOptionComponent } from "@ui5/webcomponents-ngx/fiori/filter-item-option";
import { FlexibleColumnLayoutComponent } from "@ui5/webcomponents-ngx/fiori/flexible-column-layout";
import { GroupItemComponent } from "@ui5/webcomponents-ngx/fiori/group-item";
import { IllustratedMessageComponent } from "@ui5/webcomponents-ngx/fiori/illustrated-message";
import { MediaGalleryComponent } from "@ui5/webcomponents-ngx/fiori/media-gallery";
import { MediaGalleryItemComponent } from "@ui5/webcomponents-ngx/fiori/media-gallery-item";
import { NavigationLayoutComponent } from "@ui5/webcomponents-ngx/fiori/navigation-layout";
import { NotificationListComponent } from "@ui5/webcomponents-ngx/fiori/notification-list";
import { NotificationListGroupItemComponent } from "@ui5/webcomponents-ngx/fiori/notification-list-group-item";
import { NotificationListItemComponent } from "@ui5/webcomponents-ngx/fiori/notification-list-item";
import { PageComponent } from "@ui5/webcomponents-ngx/fiori/page";
import { ProductSwitchComponent } from "@ui5/webcomponents-ngx/fiori/product-switch";
import { ProductSwitchItemComponent } from "@ui5/webcomponents-ngx/fiori/product-switch-item";
import { SearchComponent } from "@ui5/webcomponents-ngx/fiori/search";
import { SearchItemComponent } from "@ui5/webcomponents-ngx/fiori/search-item";
import { SearchItemGroupComponent } from "@ui5/webcomponents-ngx/fiori/search-item-group";
import { SearchItemShowMoreComponent } from "@ui5/webcomponents-ngx/fiori/search-item-show-more";
import { SearchMessageAreaComponent } from "@ui5/webcomponents-ngx/fiori/search-message-area";
import { SearchScopeComponent } from "@ui5/webcomponents-ngx/fiori/search-scope";
import { ShellBarComponent } from "@ui5/webcomponents-ngx/fiori/shell-bar";
import { ShellBarBrandingComponent } from "@ui5/webcomponents-ngx/fiori/shell-bar-branding";
import { ShellBarItemComponent } from "@ui5/webcomponents-ngx/fiori/shell-bar-item";
import { ShellBarSearchComponent } from "@ui5/webcomponents-ngx/fiori/shell-bar-search";
import { ShellBarSpacerComponent } from "@ui5/webcomponents-ngx/fiori/shell-bar-spacer";
import { SideNavigationComponent } from "@ui5/webcomponents-ngx/fiori/side-navigation";
import { SideNavigationGroupComponent } from "@ui5/webcomponents-ngx/fiori/side-navigation-group";
import { SideNavigationItemComponent } from "@ui5/webcomponents-ngx/fiori/side-navigation-item";
import { SideNavigationSubItemComponent } from "@ui5/webcomponents-ngx/fiori/side-navigation-sub-item";
import { SortItemComponent } from "@ui5/webcomponents-ngx/fiori/sort-item";
import { TimelineComponent } from "@ui5/webcomponents-ngx/fiori/timeline";
import { TimelineGroupItemComponent } from "@ui5/webcomponents-ngx/fiori/timeline-group-item";
import { TimelineItemComponent } from "@ui5/webcomponents-ngx/fiori/timeline-item";
import { UploadCollectionComponent } from "@ui5/webcomponents-ngx/fiori/upload-collection";
import { UploadCollectionItemComponent } from "@ui5/webcomponents-ngx/fiori/upload-collection-item";
import { UserMenuComponent } from "@ui5/webcomponents-ngx/fiori/user-menu";
import { UserMenuAccountComponent } from "@ui5/webcomponents-ngx/fiori/user-menu-account";
import { UserMenuItemComponent } from "@ui5/webcomponents-ngx/fiori/user-menu-item";
import { UserMenuItemGroupComponent } from "@ui5/webcomponents-ngx/fiori/user-menu-item-group";
import { UserSettingsAccountViewComponent } from "@ui5/webcomponents-ngx/fiori/user-settings-account-view";
import { UserSettingsAppearanceViewComponent } from "@ui5/webcomponents-ngx/fiori/user-settings-appearance-view";
import { UserSettingsAppearanceViewGroupComponent } from "@ui5/webcomponents-ngx/fiori/user-settings-appearance-view-group";
import { UserSettingsAppearanceViewItemComponent } from "@ui5/webcomponents-ngx/fiori/user-settings-appearance-view-item";
import { UserSettingsDialogComponent } from "@ui5/webcomponents-ngx/fiori/user-settings-dialog";
import { UserSettingsItemComponent } from "@ui5/webcomponents-ngx/fiori/user-settings-item";
import { UserSettingsViewComponent } from "@ui5/webcomponents-ngx/fiori/user-settings-view";
import { ViewSettingsDialogComponent } from "@ui5/webcomponents-ngx/fiori/view-settings-dialog";
import { WizardComponent } from "@ui5/webcomponents-ngx/fiori/wizard";
import { WizardStepComponent } from "@ui5/webcomponents-ngx/fiori/wizard-step";

const imports = [
  BarcodeScannerDialogComponent,
  DynamicPageComponent,
  DynamicPageHeaderComponent,
  DynamicPageTitleComponent,
  DynamicSideContentComponent,
  FilterItemComponent,
  FilterItemOptionComponent,
  FlexibleColumnLayoutComponent,
  GroupItemComponent,
  IllustratedMessageComponent,
  MediaGalleryComponent,
  MediaGalleryItemComponent,
  NavigationLayoutComponent,
  NotificationListComponent,
  NotificationListGroupItemComponent,
  NotificationListItemComponent,
  PageComponent,
  ProductSwitchComponent,
  ProductSwitchItemComponent,
  SearchComponent,
  SearchItemComponent,
  SearchItemGroupComponent,
  SearchItemShowMoreComponent,
  SearchMessageAreaComponent,
  SearchScopeComponent,
  ShellBarComponent,
  ShellBarBrandingComponent,
  ShellBarItemComponent,
  ShellBarSearchComponent,
  ShellBarSpacerComponent,
  SideNavigationComponent,
  SideNavigationGroupComponent,
  SideNavigationItemComponent,
  SideNavigationSubItemComponent,
  SortItemComponent,
  TimelineComponent,
  TimelineGroupItemComponent,
  TimelineItemComponent,
  UploadCollectionComponent,
  UploadCollectionItemComponent,
  UserMenuComponent,
  UserMenuAccountComponent,
  UserMenuItemComponent,
  UserMenuItemGroupComponent,
  UserSettingsAccountViewComponent,
  UserSettingsAppearanceViewComponent,
  UserSettingsAppearanceViewGroupComponent,
  UserSettingsAppearanceViewItemComponent,
  UserSettingsDialogComponent,
  UserSettingsItemComponent,
  UserSettingsViewComponent,
  ViewSettingsDialogComponent,
  WizardComponent,
  WizardStepComponent,
];
const exports = [...imports];

@NgModule({
  imports: [...imports],
  exports: [...exports],
})
class Ui5FioriModule {
  constructor(
    ui5WebcomponentsFioriThemingService: Ui5WebcomponentsFioriThemingService,
  ) {}
}
export { Ui5FioriModule };
