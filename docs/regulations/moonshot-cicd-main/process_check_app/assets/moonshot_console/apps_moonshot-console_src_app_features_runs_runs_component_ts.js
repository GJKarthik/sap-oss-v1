"use strict";
(self["webpackChunkmoonshot_console"] = self["webpackChunkmoonshot_console"] || []).push([["apps_moonshot-console_src_app_features_runs_runs_component_ts"],{

/***/ 3349:
/*!***********************************************************************!*\
  !*** ./apps/moonshot-console/src/app/features/runs/runs.component.ts ***!
  \***********************************************************************/
/***/ ((__unused_webpack_module, __webpack_exports__, __webpack_require__) => {

__webpack_require__.r(__webpack_exports__);
/* harmony export */ __webpack_require__.d(__webpack_exports__, {
/* harmony export */   RunsComponent: () => (/* binding */ RunsComponent)
/* harmony export */ });
/* harmony import */ var _angular_common__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! @angular/common */ 7737);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! @angular/core */ 4131);
/* harmony import */ var _angular_core_rxjs_interop__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! @angular/core/rxjs-interop */ 5768);
/* harmony import */ var _core_services_moonshot_api_service__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! ../../core/services/moonshot-api.service */ 5509);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__(/*! @angular/core */ 3499);
var _staticBlock;






function RunsComponent_ui5_option_17_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "ui5-option", 17);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](1);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const id_r1 = ctx.$implicit;
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("value", id_r1);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](id_r1);
  }
}
function RunsComponent_ui5_option_22_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "ui5-option", 17);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](1);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const c_r2 = ctx.$implicit;
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("value", c_r2);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](c_r2);
  }
}
function RunsComponent_ui5_message_strip_33_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "ui5-message-strip", 18);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](1);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵnextContext"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](ctx_r2.errorMessage);
  }
}
function RunsComponent_ui5_card_34_div_2_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "div", 21)(1, "div", 22)(2, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](3, "run_id");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](4, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](6, "div", 22)(7, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](8, "test_config_id");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](9, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](10);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](11, "div", 22)(12, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](13, "connector");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](14, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](15);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](16, "div", 22)(17, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](18, "result_path");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](19, "code");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](20);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](21, "div", 22)(22, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](23, "tests_executed");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](24, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](25);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](26, "div", 22)(27, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](28, "dry_run_prompts");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](29, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](30);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](31, "div", 22)(32, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](33, "duration_seconds");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](34, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](35);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](36, "div", 22)(37, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](38, "persisted_to_odata");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](39, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](40);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()()();
  }
  if (rf & 2) {
    const run_r4 = ctx.ngIf;
    const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵnextContext"](2);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](run_r4.run_id);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](run_r4.test_config_id);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](run_r4.connector);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](run_r4.result_path);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](run_r4.tests_executed);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](run_r4.dry_run_prompts);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](run_r4.duration_seconds);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](ctx_r2.runResponse.persisted_to_odata ? "yes" : "no");
  }
}
function RunsComponent_ui5_card_34_ng_template_3_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "div", 21)(1, "p");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](2, "Run failed.");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](3, "pre");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](4);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵpipe"](5, "json");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
  }
  if (rf & 2) {
    const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵnextContext"](2);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](4);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](_angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵpipeBind1"](5, 1, ctx_r2.runResponse));
  }
}
function RunsComponent_ui5_card_34_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "ui5-card");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelement"](1, "ui5-card-header", 19);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](2, RunsComponent_ui5_card_34_div_2_Template, 41, 8, "div", 20)(3, RunsComponent_ui5_card_34_ng_template_3_Template, 6, 3, "ng-template", null, 0, _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplateRefExtractor"]);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const failedRun_r5 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵreference"](4);
    const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵnextContext"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](2);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngIf", ctx_r2.runResponse.status === "success" && ctx_r2.runResponse.run)("ngIfElse", failedRun_r5);
  }
}
class RunsComponent {
  constructor() {
    this.destroyRef = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_angular_core__WEBPACK_IMPORTED_MODULE_1__.DestroyRef);
    this.moonshot = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_core_services_moonshot_api_service__WEBPACK_IMPORTED_MODULE_3__.MoonshotApiService);
    this.runId = this.defaultRunId();
    this.testConfigId = '';
    this.connector = '';
    this.dryRun = true;
    this.testConfigIds = [];
    this.connectors = [];
    this.submitting = false;
    this.errorMessage = '';
    this.runResponse = null;
    this.reloadCatalog();
  }
  reloadCatalog() {
    this.moonshot.getTestConfigs().pipe((0,_angular_core_rxjs_interop__WEBPACK_IMPORTED_MODULE_2__.takeUntilDestroyed)(this.destroyRef)).subscribe(tests => {
      this.testConfigIds = tests.test_config_ids ?? [];
      if (!this.testConfigId && this.testConfigIds.length > 0) {
        this.testConfigId = this.testConfigIds[0];
      }
    });
    this.moonshot.getConfigSummary().pipe((0,_angular_core_rxjs_interop__WEBPACK_IMPORTED_MODULE_2__.takeUntilDestroyed)(this.destroyRef)).subscribe(summary => {
      this.connectors = summary.connectors ?? [];
      if (!this.connector && this.connectors.length > 0) {
        this.connector = this.connectors[0];
      }
    });
  }
  triggerRun() {
    this.errorMessage = '';
    this.runResponse = null;
    if (!this.runId || !this.testConfigId || !this.connector) {
      this.errorMessage = 'run_id, test_config_id, and connector are required.';
      return;
    }
    this.submitting = true;
    this.moonshot.triggerRun({
      run_id: this.runId,
      test_config_id: this.testConfigId,
      connector: this.connector,
      dry_run: this.dryRun
    }).pipe((0,_angular_core_rxjs_interop__WEBPACK_IMPORTED_MODULE_2__.takeUntilDestroyed)(this.destroyRef)).subscribe({
      next: response => {
        this.runResponse = response;
        this.submitting = false;
      },
      error: error => {
        this.errorMessage = error.message;
        this.submitting = false;
      }
    });
  }
  valueFromEvent(event) {
    const target = event.target;
    return target.value ?? '';
  }
  checkedFromEvent(event) {
    const target = event.target;
    return !!target.checked;
  }
  defaultRunId() {
    const now = new Date();
    const stamp = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, '0')}${String(now.getDate()).padStart(2, '0')}-${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}${String(now.getSeconds()).padStart(2, '0')}`;
    return `run-${stamp}`;
  }
  static #_ = _staticBlock = () => (this.ɵfac = function RunsComponent_Factory(__ngFactoryType__) {
    return new (__ngFactoryType__ || RunsComponent)();
  }, this.ɵcmp = /*@__PURE__*/_angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵdefineComponent"]({
    type: RunsComponent,
    selectors: [["app-runs"]],
    decls: 35,
    vars: 10,
    consts: [["failedRun", ""], [1, "page"], ["level", "H2"], [1, "subtitle"], ["slot", "header", "title-text", "Run Request"], [1, "card-content", "form-grid"], [1, "field"], ["placeholder", "run id", 3, "input", "value"], [3, "change", "value"], [3, "value", 4, "ngFor", "ngForOf"], [1, "field", "inline"], [3, "change", "checked"], [1, "actions"], ["design", "Emphasized", "icon", "media-play", 3, "click", "disabled"], ["design", "Transparent", "icon", "refresh", 3, "click"], ["design", "Negative", 4, "ngIf"], [4, "ngIf"], [3, "value"], ["design", "Negative"], ["slot", "header", "title-text", "Run Result"], ["class", "card-content", 4, "ngIf", "ngIfElse"], [1, "card-content"], [1, "result-row"]],
    template: function RunsComponent_Template(rf, ctx) {
      if (rf & 1) {
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "section", 1)(1, "div")(2, "ui5-title", 2);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](3, "Trigger Moonshot Run");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](4, "p", 3);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](5, "Calls POST /api/moonshot/runs and persists run metadata through OData.");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](6, "ui5-card");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelement"](7, "ui5-card-header", 4);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](8, "div", 5)(9, "label", 6)(10, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](11, "run_id");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](12, "ui5-input", 7);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵlistener"]("input", function RunsComponent_Template_ui5_input_input_12_listener($event) {
          return ctx.runId = ctx.valueFromEvent($event);
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](13, "label", 6)(14, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](15, "test_config_id");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](16, "ui5-select", 8);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵlistener"]("change", function RunsComponent_Template_ui5_select_change_16_listener($event) {
          return ctx.testConfigId = ctx.valueFromEvent($event);
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](17, RunsComponent_ui5_option_17_Template, 2, 2, "ui5-option", 9);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](18, "label", 6)(19, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](20, "connector");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](21, "ui5-select", 8);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵlistener"]("change", function RunsComponent_Template_ui5_select_change_21_listener($event) {
          return ctx.connector = ctx.valueFromEvent($event);
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](22, RunsComponent_ui5_option_22_Template, 2, 2, "ui5-option", 9);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](23, "label", 10)(24, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](25, "dry_run");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](26, "ui5-checkbox", 11);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵlistener"]("change", function RunsComponent_Template_ui5_checkbox_change_26_listener($event) {
          return ctx.dryRun = ctx.checkedFromEvent($event);
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](27, "Enable dry run");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](28, "div", 12)(29, "ui5-button", 13);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵlistener"]("click", function RunsComponent_Template_ui5_button_click_29_listener() {
          return ctx.triggerRun();
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](30);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](31, "ui5-button", 14);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵlistener"]("click", function RunsComponent_Template_ui5_button_click_31_listener() {
          return ctx.reloadCatalog();
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](32, "Reload Options");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](33, RunsComponent_ui5_message_strip_33_Template, 2, 1, "ui5-message-strip", 15)(34, RunsComponent_ui5_card_34_Template, 5, 2, "ui5-card", 16);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
      }
      if (rf & 2) {
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](12);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("value", ctx.runId);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](4);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("value", ctx.testConfigId);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngForOf", ctx.testConfigIds);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](4);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("value", ctx.connector);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngForOf", ctx.connectors);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](4);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("checked", ctx.dryRun);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](3);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("disabled", ctx.submitting);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate1"](" ", ctx.submitting ? "Running..." : "Run Moonshot Test", " ");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](3);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngIf", ctx.errorMessage);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngIf", ctx.runResponse);
      }
    },
    dependencies: [_angular_common__WEBPACK_IMPORTED_MODULE_0__.CommonModule, _angular_common__WEBPACK_IMPORTED_MODULE_0__.NgForOf, _angular_common__WEBPACK_IMPORTED_MODULE_0__.NgIf, _angular_common__WEBPACK_IMPORTED_MODULE_0__.JsonPipe],
    styles: [".page[_ngcontent-%COMP%] {\n  display: grid;\n  gap: 1rem;\n}\n\n.subtitle[_ngcontent-%COMP%] {\n  margin: 0.4rem 0 0;\n  color: var(--sapContent_LabelColor);\n}\n\n.card-content[_ngcontent-%COMP%] {\n  padding: 1rem;\n}\n\n.form-grid[_ngcontent-%COMP%] {\n  display: grid;\n  grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));\n  gap: 0.9rem;\n}\n\n.field[_ngcontent-%COMP%] {\n  display: grid;\n  gap: 0.35rem;\n}\n\n.field[_ngcontent-%COMP%]   span[_ngcontent-%COMP%] {\n  font-size: 0.78rem;\n  color: var(--sapContent_LabelColor);\n}\n\n.inline[_ngcontent-%COMP%] {\n  align-items: end;\n}\n\n.actions[_ngcontent-%COMP%] {\n  padding: 0 1rem 1rem;\n  display: flex;\n  gap: 0.6rem;\n}\n\n.result-row[_ngcontent-%COMP%] {\n  display: flex;\n  justify-content: space-between;\n  gap: 1rem;\n  margin-bottom: 0.45rem;\n}\n\npre[_ngcontent-%COMP%] {\n  margin: 0;\n  white-space: pre-wrap;\n  word-break: break-word;\n}\n/*# sourceMappingURL=data:application/json;charset=utf-8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIndlYnBhY2s6Ly8uL2FwcHMvbW9vbnNob3QtY29uc29sZS9zcmMvYXBwL2ZlYXR1cmVzL3J1bnMvcnVucy5jb21wb25lbnQudHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IkFBQ007RUFDRSxhQUFBO0VBQ0EsU0FBQTtBQUFSOztBQUdNO0VBQ0Usa0JBQUE7RUFDQSxtQ0FBQTtBQUFSOztBQUdNO0VBQ0UsYUFBQTtBQUFSOztBQUdNO0VBQ0UsYUFBQTtFQUNBLDJEQUFBO0VBQ0EsV0FBQTtBQUFSOztBQUdNO0VBQ0UsYUFBQTtFQUNBLFlBQUE7QUFBUjs7QUFHTTtFQUNFLGtCQUFBO0VBQ0EsbUNBQUE7QUFBUjs7QUFHTTtFQUNFLGdCQUFBO0FBQVI7O0FBR007RUFDRSxvQkFBQTtFQUNBLGFBQUE7RUFDQSxXQUFBO0FBQVI7O0FBR007RUFDRSxhQUFBO0VBQ0EsOEJBQUE7RUFDQSxTQUFBO0VBQ0Esc0JBQUE7QUFBUjs7QUFHTTtFQUNFLFNBQUE7RUFDQSxxQkFBQTtFQUNBLHNCQUFBO0FBQVIiLCJzb3VyY2VzQ29udGVudCI6WyJcbiAgICAgIC5wYWdlIHtcbiAgICAgICAgZGlzcGxheTogZ3JpZDtcbiAgICAgICAgZ2FwOiAxcmVtO1xuICAgICAgfVxuXG4gICAgICAuc3VidGl0bGUge1xuICAgICAgICBtYXJnaW46IDAuNHJlbSAwIDA7XG4gICAgICAgIGNvbG9yOiB2YXIoLS1zYXBDb250ZW50X0xhYmVsQ29sb3IpO1xuICAgICAgfVxuXG4gICAgICAuY2FyZC1jb250ZW50IHtcbiAgICAgICAgcGFkZGluZzogMXJlbTtcbiAgICAgIH1cblxuICAgICAgLmZvcm0tZ3JpZCB7XG4gICAgICAgIGRpc3BsYXk6IGdyaWQ7XG4gICAgICAgIGdyaWQtdGVtcGxhdGUtY29sdW1uczogcmVwZWF0KGF1dG8tZml0LCBtaW5tYXgoMjIwcHgsIDFmcikpO1xuICAgICAgICBnYXA6IDAuOXJlbTtcbiAgICAgIH1cblxuICAgICAgLmZpZWxkIHtcbiAgICAgICAgZGlzcGxheTogZ3JpZDtcbiAgICAgICAgZ2FwOiAwLjM1cmVtO1xuICAgICAgfVxuXG4gICAgICAuZmllbGQgc3BhbiB7XG4gICAgICAgIGZvbnQtc2l6ZTogMC43OHJlbTtcbiAgICAgICAgY29sb3I6IHZhcigtLXNhcENvbnRlbnRfTGFiZWxDb2xvcik7XG4gICAgICB9XG5cbiAgICAgIC5pbmxpbmUge1xuICAgICAgICBhbGlnbi1pdGVtczogZW5kO1xuICAgICAgfVxuXG4gICAgICAuYWN0aW9ucyB7XG4gICAgICAgIHBhZGRpbmc6IDAgMXJlbSAxcmVtO1xuICAgICAgICBkaXNwbGF5OiBmbGV4O1xuICAgICAgICBnYXA6IDAuNnJlbTtcbiAgICAgIH1cblxuICAgICAgLnJlc3VsdC1yb3cge1xuICAgICAgICBkaXNwbGF5OiBmbGV4O1xuICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47XG4gICAgICAgIGdhcDogMXJlbTtcbiAgICAgICAgbWFyZ2luLWJvdHRvbTogMC40NXJlbTtcbiAgICAgIH1cblxuICAgICAgcHJlIHtcbiAgICAgICAgbWFyZ2luOiAwO1xuICAgICAgICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7XG4gICAgICAgIHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7XG4gICAgICB9XG4gICAgIl0sInNvdXJjZVJvb3QiOiIifQ== */"]
  }));
}
_staticBlock();

/***/ })

}]);
//# sourceMappingURL=apps_moonshot-console_src_app_features_runs_runs_component_ts.js.map