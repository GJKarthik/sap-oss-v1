"use strict";
(self["webpackChunkmoonshot_console"] = self["webpackChunkmoonshot_console"] || []).push([["main"],{

/***/ 3432:
/*!*****************************************************!*\
  !*** ./apps/moonshot-console/src/app/app.routes.ts ***!
  \*****************************************************/
/***/ ((__unused_webpack_module, __webpack_exports__, __webpack_require__) => {

__webpack_require__.r(__webpack_exports__);
/* harmony export */ __webpack_require__.d(__webpack_exports__, {
/* harmony export */   routes: () => (/* binding */ routes)
/* harmony export */ });
const routes = [{
  path: '',
  redirectTo: 'welcome',
  pathMatch: 'full'
}, {
  path: 'welcome',
  loadComponent: () => __webpack_require__.e(/*! import() */ "apps_moonshot-console_src_app_features_welcome_welcome_component_ts").then(__webpack_require__.bind(__webpack_require__, /*! ./features/welcome/welcome.component */ 5907)).then(m => m.WelcomeComponent)
}, {
  path: 'getting-started',
  loadComponent: () => __webpack_require__.e(/*! import() */ "apps_moonshot-console_src_app_features_getting-started_getting-started_component_ts").then(__webpack_require__.bind(__webpack_require__, /*! ./features/getting-started/getting-started.component */ 3223)).then(m => m.GettingStartedComponent)
}, {
  path: 'process-checks',
  loadComponent: () => __webpack_require__.e(/*! import() */ "apps_moonshot-console_src_app_features_process-checks_process-checks_component_ts").then(__webpack_require__.bind(__webpack_require__, /*! ./features/process-checks/process-checks.component */ 9155)).then(m => m.ProcessChecksComponent)
}, {
  path: 'upload-results',
  loadComponent: () => __webpack_require__.e(/*! import() */ "apps_moonshot-console_src_app_features_upload-results_upload-results_component_ts").then(__webpack_require__.bind(__webpack_require__, /*! ./features/upload-results/upload-results.component */ 6953)).then(m => m.UploadResultsComponent)
}, {
  path: 'generate-report',
  loadComponent: () => __webpack_require__.e(/*! import() */ "apps_moonshot-console_src_app_features_generate-report_generate-report_component_ts").then(__webpack_require__.bind(__webpack_require__, /*! ./features/generate-report/generate-report.component */ 7971)).then(m => m.GenerateReportComponent)
}, {
  path: 'overview',
  loadComponent: () => __webpack_require__.e(/*! import() */ "apps_moonshot-console_src_app_features_overview_overview_component_ts").then(__webpack_require__.bind(__webpack_require__, /*! ./features/overview/overview.component */ 7987)).then(m => m.OverviewComponent)
}, {
  path: 'catalog',
  loadComponent: () => __webpack_require__.e(/*! import() */ "apps_moonshot-console_src_app_features_catalog_catalog_component_ts").then(__webpack_require__.bind(__webpack_require__, /*! ./features/catalog/catalog.component */ 3963)).then(m => m.CatalogComponent)
}, {
  path: 'runs',
  loadComponent: () => __webpack_require__.e(/*! import() */ "apps_moonshot-console_src_app_features_runs_runs_component_ts").then(__webpack_require__.bind(__webpack_require__, /*! ./features/runs/runs.component */ 3349)).then(m => m.RunsComponent)
}, {
  path: 'history',
  loadComponent: () => __webpack_require__.e(/*! import() */ "apps_moonshot-console_src_app_features_history_history_component_ts").then(__webpack_require__.bind(__webpack_require__, /*! ./features/history/history.component */ 7435)).then(m => m.HistoryComponent)
}, {
  path: 'settings',
  loadComponent: () => __webpack_require__.e(/*! import() */ "apps_moonshot-console_src_app_features_settings_settings_component_ts").then(__webpack_require__.bind(__webpack_require__, /*! ./features/settings/settings.component */ 2031)).then(m => m.SettingsComponent)
}, {
  path: '**',
  redirectTo: 'welcome'
}];

/***/ }),

/***/ 5509:
/*!*****************************************************************************!*\
  !*** ./apps/moonshot-console/src/app/core/services/moonshot-api.service.ts ***!
  \*****************************************************************************/
/***/ ((__unused_webpack_module, __webpack_exports__, __webpack_require__) => {

__webpack_require__.r(__webpack_exports__);
/* harmony export */ __webpack_require__.d(__webpack_exports__, {
/* harmony export */   MoonshotApiService: () => (/* binding */ MoonshotApiService)
/* harmony export */ });
/* harmony import */ var _angular_common_http__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! @angular/common/http */ 1693);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! @angular/core */ 4131);
/* harmony import */ var rxjs__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! rxjs */ 3485);
/* harmony import */ var rxjs__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! rxjs */ 7796);
/* harmony import */ var rxjs__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__(/*! rxjs */ 5463);
/* harmony import */ var rxjs__WEBPACK_IMPORTED_MODULE_5__ = __webpack_require__(/*! rxjs */ 494);
/* harmony import */ var rxjs__WEBPACK_IMPORTED_MODULE_6__ = __webpack_require__(/*! rxjs */ 6663);
/* harmony import */ var rxjs__WEBPACK_IMPORTED_MODULE_7__ = __webpack_require__(/*! rxjs */ 1252);
var _staticBlock;




const STORAGE_KEY = 'moonshot_console_config';
const DEFAULT_CONFIG = {
  baseUrl: 'http://localhost:8088',
  useMockFallback: true,
  timeoutMs: 30000
};
class MoonshotApiService {
  constructor() {
    this.http = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_angular_common_http__WEBPACK_IMPORTED_MODULE_0__.HttpClient);
    this.configSubject = new rxjs__WEBPACK_IMPORTED_MODULE_2__.BehaviorSubject(this.loadConfig());
    this.config$ = this.configSubject.asObservable();
    this.fallbackSubject = new rxjs__WEBPACK_IMPORTED_MODULE_2__.BehaviorSubject(false);
    this.fallbackMode$ = this.fallbackSubject.asObservable();
    this.lastErrorSubject = new rxjs__WEBPACK_IMPORTED_MODULE_2__.BehaviorSubject(null);
    this.lastError$ = this.lastErrorSubject.asObservable();
    this.mockRuns = [{
      run_id: 'sample-offline-run',
      test_config_id: 'sample_test',
      connector: 'my-gpt-4o',
      status: 'completed',
      result_path: 'data/results/sample-offline-run.json',
      start_time_unix: Math.floor(Date.now() / 1000) - 180,
      end_time_unix: Math.floor(Date.now() / 1000) - 120,
      duration_seconds: 60,
      dry_run_prompts: 5
    }];
  }
  getConfig() {
    return {
      ...this.configSubject.value
    };
  }
  setConfig(partial) {
    const next = {
      ...this.configSubject.value,
      ...partial
    };
    this.configSubject.next(next);
    this.saveConfig(next);
  }
  checkHealth() {
    const url = `${this.baseUrl()}/api/moonshot/health`;
    const request$ = this.http.get(url);
    return this.withFallback(request$, () => ({
      status: 'ok',
      service: 'moonshot-gateway',
      moonshot_root: 'regulations/moonshot-cicd-main',
      moonshot_binary: '',
      binary_exists: false,
      odata_base_url: 'http://127.0.0.1:9882',
      odata_reachable: false
    }), 'Moonshot health check');
  }
  getConfigSummary() {
    const url = `${this.baseUrl()}/api/moonshot/config/summary`;
    const request$ = this.http.get(url);
    return this.withFallback(request$, () => ({
      status: 'ok',
      common: {
        max_concurrency: 5,
        max_calls_per_minute: 60,
        max_attempts: 3
      },
      connectors: ['my-gpt-4o', 'my-gpt-4.1-mini'],
      metrics: ['exact_match', 'refusal_adapter'],
      attack_modules: ['prompt_injection'],
      connector_count: 2,
      metric_count: 2,
      attack_module_count: 1
    }), 'Moonshot config summary');
  }
  getTestConfigs() {
    const url = `${this.baseUrl()}/api/moonshot/test-configs`;
    const request$ = this.http.get(url);
    return this.withFallback(request$, () => ({
      status: 'ok',
      test_config_ids: ['sample_test'],
      test_configs: {
        sample_test: [{
          name: 'Sample Benchmark',
          type: 'benchmark',
          dataset: 'sample_dataset',
          metric: 'exact_match'
        }]
      }
    }), 'Moonshot test config list');
  }
  triggerRun(payload) {
    const url = `${this.baseUrl()}/api/moonshot/runs`;
    const request$ = this.http.post(url, payload).pipe((0,rxjs__WEBPACK_IMPORTED_MODULE_6__.map)(response => {
      if (response.status === 'error') {
        const reason = response.error ?? response.stderr ?? 'Unknown execution error';
        throw new Error(reason);
      }
      return response;
    }));
    return this.withFallback(request$, () => {
      const started = Math.floor(Date.now() / 1000);
      const output = {
        status: 'success',
        run_id: payload.run_id,
        test_config_id: payload.test_config_id,
        connector: payload.connector,
        result_path: `data/results/${payload.run_id}.json`,
        tests_executed: 1,
        dry_run_prompts: payload.dry_run ? 5 : 0,
        duration_seconds: 1
      };
      this.mockRuns.unshift({
        run_id: output.run_id,
        test_config_id: output.test_config_id,
        connector: output.connector,
        status: 'completed',
        result_path: output.result_path,
        start_time_unix: started,
        end_time_unix: started + 1,
        duration_seconds: 1,
        dry_run_prompts: output.dry_run_prompts
      });
      return {
        status: 'success',
        run: output,
        persisted_to_odata: false
      };
    }, 'Moonshot run execution');
  }
  listRuns() {
    const url = `${this.baseUrl()}/api/moonshot/runs`;
    const request$ = this.http.get(url);
    return this.withFallback(request$, () => ({
      runs: [...this.mockRuns]
    }), 'Moonshot run history');
  }
  getRun(runId) {
    const url = `${this.baseUrl()}/api/moonshot/runs/${encodeURIComponent(runId)}`;
    const request$ = this.http.get(url);
    return this.withFallback(request$, () => ({
      run: this.mockRuns.find(run => run.run_id === runId) ?? null
    }), 'Moonshot run detail');
  }
  withFallback(request$, mockFactory, context) {
    return request$.pipe((0,rxjs__WEBPACK_IMPORTED_MODULE_7__.tap)(() => {
      this.fallbackSubject.next(false);
      this.lastErrorSubject.next(null);
    }), (0,rxjs__WEBPACK_IMPORTED_MODULE_5__.catchError)(error => {
      const message = this.describeHttpError(context, error);
      this.lastErrorSubject.next(message);
      if (this.configSubject.value.useMockFallback) {
        this.fallbackSubject.next(true);
        return (0,rxjs__WEBPACK_IMPORTED_MODULE_3__.of)(mockFactory());
      }
      this.fallbackSubject.next(false);
      return (0,rxjs__WEBPACK_IMPORTED_MODULE_4__.throwError)(() => new Error(message));
    }));
  }
  baseUrl() {
    return this.configSubject.value.baseUrl.replace(/\/$/, '');
  }
  describeHttpError(context, error) {
    const errorObject = error;
    const reason = errorObject.error?.message ?? errorObject.message ?? 'Request failed';
    const status = errorObject.status ? `HTTP ${errorObject.status}` : 'network error';
    return `${context}: ${status} - ${reason}`;
  }
  loadConfig() {
    if (typeof window === 'undefined') {
      return {
        ...DEFAULT_CONFIG
      };
    }
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      return {
        ...DEFAULT_CONFIG
      };
    }
    try {
      const parsed = JSON.parse(raw);
      return {
        ...DEFAULT_CONFIG,
        ...parsed
      };
    } catch {
      return {
        ...DEFAULT_CONFIG
      };
    }
  }
  saveConfig(config) {
    if (typeof window === 'undefined') {
      return;
    }
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
  }
  static #_ = _staticBlock = () => (this.ɵfac = function MoonshotApiService_Factory(__ngFactoryType__) {
    return new (__ngFactoryType__ || MoonshotApiService)();
  }, this.ɵprov = /*@__PURE__*/_angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵdefineInjectable"]({
    token: MoonshotApiService,
    factory: MoonshotApiService.ɵfac,
    providedIn: 'root'
  }));
}
_staticBlock();

/***/ }),

/***/ 7244:
/*!*******************************************!*\
  !*** ./apps/moonshot-console/src/main.ts ***!
  \*******************************************/
/***/ ((__unused_webpack_module, __webpack_exports__, __webpack_require__) => {

__webpack_require__.r(__webpack_exports__);
/* harmony import */ var _angular_common_http__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! @angular/common/http */ 1693);
/* harmony import */ var _angular_platform_browser__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! @angular/platform-browser */ 4800);
/* harmony import */ var _angular_router__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! @angular/router */ 709);
/* harmony import */ var _app_app_component__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! ./app/app.component */ 8575);
/* harmony import */ var _app_app_routes__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__(/*! ./app/app.routes */ 3432);





(0,_angular_platform_browser__WEBPACK_IMPORTED_MODULE_1__.bootstrapApplication)(_app_app_component__WEBPACK_IMPORTED_MODULE_3__.AppComponent, {
  providers: [(0,_angular_router__WEBPACK_IMPORTED_MODULE_2__.provideRouter)(_app_app_routes__WEBPACK_IMPORTED_MODULE_4__.routes, (0,_angular_router__WEBPACK_IMPORTED_MODULE_2__.withHashLocation)()), (0,_angular_common_http__WEBPACK_IMPORTED_MODULE_0__.provideHttpClient)()]
}).catch(err => console.error(err));

/***/ }),

/***/ 8575:
/*!********************************************************!*\
  !*** ./apps/moonshot-console/src/app/app.component.ts ***!
  \********************************************************/
/***/ ((__unused_webpack_module, __webpack_exports__, __webpack_require__) => {

__webpack_require__.r(__webpack_exports__);
/* harmony export */ __webpack_require__.d(__webpack_exports__, {
/* harmony export */   AppComponent: () => (/* binding */ AppComponent)
/* harmony export */ });
/* harmony import */ var _angular_common__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! @angular/common */ 7737);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! @angular/core */ 4131);
/* harmony import */ var _angular_core_rxjs_interop__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! @angular/core/rxjs-interop */ 5768);
/* harmony import */ var _angular_router__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! @angular/router */ 3288);
/* harmony import */ var rxjs__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__(/*! rxjs */ 5687);
/* harmony import */ var _core_services_moonshot_api_service__WEBPACK_IMPORTED_MODULE_5__ = __webpack_require__(/*! ./core/services/moonshot-api.service */ 5509);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_6__ = __webpack_require__(/*! @angular/core */ 3499);
var _staticBlock;








function AppComponent_ui5_side_navigation_item_4_Template(rf, ctx) {
  if (rf & 1) {
    const _r1 = _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵgetCurrentView"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementStart"](0, "ui5-side-navigation-item", 10);
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵlistener"]("click", function AppComponent_ui5_side_navigation_item_4_Template_ui5_side_navigation_item_click_0_listener() {
      const item_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵrestoreView"](_r1).$implicit;
      const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵnextContext"]();
      return _angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵresetView"](ctx_r2.navigate(item_r2.path));
    });
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const item_r2 = ctx.$implicit;
    const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵnextContext"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵproperty"]("icon", item_r2.icon)("text", item_r2.title)("selected", ctx_r2.isActive(item_r2.path));
  }
}
function AppComponent_ui5_side_navigation_item_5_Template(rf, ctx) {
  if (rf & 1) {
    const _r4 = _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵgetCurrentView"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementStart"](0, "ui5-side-navigation-item", 11);
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵlistener"]("click", function AppComponent_ui5_side_navigation_item_5_Template_ui5_side_navigation_item_click_0_listener() {
      const item_r5 = _angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵrestoreView"](_r4).$implicit;
      const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵnextContext"]();
      return _angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵresetView"](ctx_r2.navigate(item_r5.path));
    });
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const item_r5 = ctx.$implicit;
    const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵnextContext"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵproperty"]("icon", item_r5.icon)("text", item_r5.title)("selected", ctx_r2.isActive(item_r5.path));
  }
}
function AppComponent_ui5_message_strip_11_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementStart"](0, "ui5-message-strip", 12);
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵtext"](1);
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const lastError_r6 = ctx.ngIf;
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵtextInterpolate1"](" ", lastError_r6, " ");
  }
}
class AppComponent {
  constructor() {
    this.router = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_angular_router__WEBPACK_IMPORTED_MODULE_3__.Router);
    this.destroyRef = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_angular_core__WEBPACK_IMPORTED_MODULE_1__.DestroyRef);
    this.moonshot = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_core_services_moonshot_api_service__WEBPACK_IMPORTED_MODULE_5__.MoonshotApiService);
    this.topNavItems = [{
      path: '/welcome',
      title: 'Welcome',
      icon: 'home'
    }, {
      path: '/getting-started',
      title: 'Getting Started',
      icon: 'activate'
    }, {
      path: '/process-checks',
      title: 'Process Checks',
      icon: 'survey'
    }, {
      path: '/upload-results',
      title: 'Upload Results',
      icon: 'upload'
    }, {
      path: '/generate-report',
      title: 'Generate Report',
      icon: 'document-text'
    }, {
      path: '/runs',
      title: 'Moonshot Run',
      icon: 'media-play'
    }, {
      path: '/history',
      title: 'History',
      icon: 'history'
    }];
    this.fixedNavItems = [{
      path: '/overview',
      title: 'Runtime',
      icon: 'inspect'
    }, {
      path: '/catalog',
      title: 'Catalog',
      icon: 'list'
    }, {
      path: '/settings',
      title: 'Settings',
      icon: 'action-settings',
      fixed: true
    }];
    this.config$ = this.moonshot.config$;
    this.fallbackMode$ = this.moonshot.fallbackMode$;
    this.lastError$ = this.moonshot.lastError$;
    this.connectionState = 'disconnected';
    this.currentPath = '/welcome';
    this.router.events.pipe((0,rxjs__WEBPACK_IMPORTED_MODULE_4__.filter)(event => event instanceof _angular_router__WEBPACK_IMPORTED_MODULE_3__.NavigationEnd), (0,_angular_core_rxjs_interop__WEBPACK_IMPORTED_MODULE_2__.takeUntilDestroyed)(this.destroyRef)).subscribe(event => {
      this.currentPath = event.urlAfterRedirects || '/welcome';
    });
    this.refreshHealth();
  }
  isActive(path) {
    return this.currentPath === path || this.currentPath.startsWith(`${path}/`);
  }
  navigate(path) {
    void this.router.navigateByUrl(path);
  }
  refreshHealth() {
    this.connectionState = 'connecting';
    this.moonshot.checkHealth().pipe((0,_angular_core_rxjs_interop__WEBPACK_IMPORTED_MODULE_2__.takeUntilDestroyed)(this.destroyRef)).subscribe({
      next: health => {
        this.connectionState = health.odata_reachable ? 'connected' : 'degraded';
      },
      error: () => {
        this.connectionState = 'error';
      }
    });
  }
  statusDesign() {
    switch (this.connectionState) {
      case 'connected':
        return 'Positive';
      case 'connecting':
        return 'Information';
      case 'degraded':
      case 'disconnected':
        return 'Warning';
      case 'error':
      default:
        return 'Negative';
    }
  }
  statusMessage() {
    const config = this.moonshot.getConfig();
    switch (this.connectionState) {
      case 'connected':
        return `Moonshot backend connected: ${config.baseUrl} (Fabric + OData reachable)`;
      case 'degraded':
        return `Connected to ${config.baseUrl} with degraded persistence path`;
      case 'connecting':
        return `Connecting to Moonshot backend at ${config.baseUrl}...`;
      case 'error':
        return `Moonshot backend connection failed for ${config.baseUrl}`;
      case 'disconnected':
      default:
        return `Moonshot backend not connected. Current URL: ${config.baseUrl}`;
    }
  }
  static #_ = _staticBlock = () => (this.ɵfac = function AppComponent_Factory(__ngFactoryType__) {
    return new (__ngFactoryType__ || AppComponent)();
  }, this.ɵcmp = /*@__PURE__*/_angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵdefineComponent"]({
    type: AppComponent,
    selectors: [["app-root"]],
    decls: 14,
    vars: 7,
    consts: [["primary-title", "Process Check Console", "secondary-title", "Angular UI5 Runtime (Streamlit Replaced)", "show-notifications", "", 1, "shellbar"], ["slot", "profile", "initials", "PC"], [1, "layout"], [1, "side-nav"], [3, "icon", "text", "selected", "click", 4, "ngFor", "ngForOf"], ["slot", "fixedItems", 3, "icon", "text", "selected", "click", 4, "ngFor", "ngForOf"], [1, "main"], ["hide-close-button", "", 1, "status-strip", 3, "design"], ["slot", "endButton", "design", "Transparent", "icon", "refresh", 3, "click"], ["class", "status-strip", "design", "Negative", 4, "ngIf"], [3, "click", "icon", "text", "selected"], ["slot", "fixedItems", 3, "click", "icon", "text", "selected"], ["design", "Negative", 1, "status-strip"]],
    template: function AppComponent_Template(rf, ctx) {
      if (rf & 1) {
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementStart"](0, "ui5-shellbar", 0);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelement"](1, "ui5-avatar", 1);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementStart"](2, "div", 2)(3, "ui5-side-navigation", 3);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵtemplate"](4, AppComponent_ui5_side_navigation_item_4_Template, 1, 3, "ui5-side-navigation-item", 4)(5, AppComponent_ui5_side_navigation_item_5_Template, 1, 3, "ui5-side-navigation-item", 5);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementStart"](6, "main", 6)(7, "ui5-message-strip", 7);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵtext"](8);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementStart"](9, "ui5-button", 8);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵlistener"]("click", function AppComponent_Template_ui5_button_click_9_listener() {
          return ctx.refreshHealth();
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵtext"](10, " Refresh ");
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵtemplate"](11, AppComponent_ui5_message_strip_11_Template, 2, 1, "ui5-message-strip", 9);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵpipe"](12, "async");
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelement"](13, "router-outlet");
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵelementEnd"]()();
      }
      if (rf & 2) {
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵadvance"](4);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵproperty"]("ngForOf", ctx.topNavItems);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵadvance"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵproperty"]("ngForOf", ctx.fixedNavItems);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵadvance"](2);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵproperty"]("design", ctx.statusDesign());
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵadvance"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵtextInterpolate1"](" ", ctx.statusMessage(), " ");
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵadvance"](3);
        _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵproperty"]("ngIf", _angular_core__WEBPACK_IMPORTED_MODULE_6__["ɵɵpipeBind1"](12, 5, ctx.lastError$));
      }
    },
    dependencies: [_angular_common__WEBPACK_IMPORTED_MODULE_0__.CommonModule, _angular_common__WEBPACK_IMPORTED_MODULE_0__.NgForOf, _angular_common__WEBPACK_IMPORTED_MODULE_0__.NgIf, _angular_router__WEBPACK_IMPORTED_MODULE_3__.RouterOutlet, _angular_common__WEBPACK_IMPORTED_MODULE_0__.AsyncPipe],
    styles: ["[_nghost-%COMP%] {\n  display: block;\n  min-height: 100vh;\n}\n\n.shellbar[_ngcontent-%COMP%] {\n  position: sticky;\n  top: 0;\n  z-index: 15;\n  border-bottom: 1px solid var(--moonshot-border);\n}\n\n.layout[_ngcontent-%COMP%] {\n  display: grid;\n  grid-template-columns: 248px 1fr;\n  min-height: calc(100vh - 3rem);\n}\n\n.side-nav[_ngcontent-%COMP%] {\n  border-right: 1px solid var(--moonshot-border);\n  background: linear-gradient(160deg, #f3f9ff 0%, #eaf2fb 100%);\n}\n\n.main[_ngcontent-%COMP%] {\n  padding: 1rem 1.2rem 1.4rem;\n  overflow: auto;\n}\n\n.status-strip[_ngcontent-%COMP%] {\n  margin-bottom: 0.7rem;\n}\n\n@media (max-width: 980px) {\n  .layout[_ngcontent-%COMP%] {\n    grid-template-columns: 1fr;\n  }\n  .side-nav[_ngcontent-%COMP%] {\n    border-right: none;\n    border-bottom: 1px solid var(--moonshot-border);\n  }\n}\n/*# sourceMappingURL=data:application/json;charset=utf-8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIndlYnBhY2s6Ly8uL2FwcHMvbW9vbnNob3QtY29uc29sZS9zcmMvYXBwL2FwcC5jb21wb25lbnQudHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IkFBQ007RUFDRSxjQUFBO0VBQ0EsaUJBQUE7QUFBUjs7QUFHTTtFQUNFLGdCQUFBO0VBQ0EsTUFBQTtFQUNBLFdBQUE7RUFDQSwrQ0FBQTtBQUFSOztBQUdNO0VBQ0UsYUFBQTtFQUNBLGdDQUFBO0VBQ0EsOEJBQUE7QUFBUjs7QUFHTTtFQUNFLDhDQUFBO0VBQ0EsNkRBQUE7QUFBUjs7QUFHTTtFQUNFLDJCQUFBO0VBQ0EsY0FBQTtBQUFSOztBQUdNO0VBQ0UscUJBQUE7QUFBUjs7QUFHTTtFQUNFO0lBQ0UsMEJBQUE7RUFBUjtFQUdNO0lBQ0Usa0JBQUE7SUFDQSwrQ0FBQTtFQURSO0FBQ0YiLCJzb3VyY2VzQ29udGVudCI6WyJcbiAgICAgIDpob3N0IHtcbiAgICAgICAgZGlzcGxheTogYmxvY2s7XG4gICAgICAgIG1pbi1oZWlnaHQ6IDEwMHZoO1xuICAgICAgfVxuXG4gICAgICAuc2hlbGxiYXIge1xuICAgICAgICBwb3NpdGlvbjogc3RpY2t5O1xuICAgICAgICB0b3A6IDA7XG4gICAgICAgIHotaW5kZXg6IDE1O1xuICAgICAgICBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tbW9vbnNob3QtYm9yZGVyKTtcbiAgICAgIH1cblxuICAgICAgLmxheW91dCB7XG4gICAgICAgIGRpc3BsYXk6IGdyaWQ7XG4gICAgICAgIGdyaWQtdGVtcGxhdGUtY29sdW1uczogMjQ4cHggMWZyO1xuICAgICAgICBtaW4taGVpZ2h0OiBjYWxjKDEwMHZoIC0gM3JlbSk7XG4gICAgICB9XG5cbiAgICAgIC5zaWRlLW5hdiB7XG4gICAgICAgIGJvcmRlci1yaWdodDogMXB4IHNvbGlkIHZhcigtLW1vb25zaG90LWJvcmRlcik7XG4gICAgICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxNjBkZWcsICNmM2Y5ZmYgMCUsICNlYWYyZmIgMTAwJSk7XG4gICAgICB9XG5cbiAgICAgIC5tYWluIHtcbiAgICAgICAgcGFkZGluZzogMXJlbSAxLjJyZW0gMS40cmVtO1xuICAgICAgICBvdmVyZmxvdzogYXV0bztcbiAgICAgIH1cblxuICAgICAgLnN0YXR1cy1zdHJpcCB7XG4gICAgICAgIG1hcmdpbi1ib3R0b206IDAuN3JlbTtcbiAgICAgIH1cblxuICAgICAgQG1lZGlhIChtYXgtd2lkdGg6IDk4MHB4KSB7XG4gICAgICAgIC5sYXlvdXQge1xuICAgICAgICAgIGdyaWQtdGVtcGxhdGUtY29sdW1uczogMWZyO1xuICAgICAgICB9XG5cbiAgICAgICAgLnNpZGUtbmF2IHtcbiAgICAgICAgICBib3JkZXItcmlnaHQ6IG5vbmU7XG4gICAgICAgICAgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHZhcigtLW1vb25zaG90LWJvcmRlcik7XG4gICAgICAgIH1cbiAgICAgIH1cbiAgICAiXSwic291cmNlUm9vdCI6IiJ9 */"]
  }));
}
_staticBlock();

/***/ })

},
/******/ __webpack_require__ => { // webpackRuntimeModules
/******/ var __webpack_exec__ = (moduleId) => (__webpack_require__(__webpack_require__.s = moduleId))
/******/ __webpack_require__.O(0, ["vendor"], () => (__webpack_exec__(7244)));
/******/ var __webpack_exports__ = __webpack_require__.O();
/******/ }
]);
//# sourceMappingURL=main.js.map