"use strict";
(self["webpackChunkmoonshot_console"] = self["webpackChunkmoonshot_console"] || []).push([["apps_moonshot-console_src_app_features_generate-report_generate-report_component_ts"],{

/***/ 7971:
/*!*********************************************************************************************!*\
  !*** ./apps/moonshot-console/src/app/features/generate-report/generate-report.component.ts ***!
  \*********************************************************************************************/
/***/ ((__unused_webpack_module, __webpack_exports__, __webpack_require__) => {

__webpack_require__.r(__webpack_exports__);
/* harmony export */ __webpack_require__.d(__webpack_exports__, {
/* harmony export */   GenerateReportComponent: () => (/* binding */ GenerateReportComponent)
/* harmony export */ });
/* harmony import */ var _angular_common__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! @angular/common */ 7737);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! @angular/core */ 4131);
/* harmony import */ var _angular_router__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! @angular/router */ 3288);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! @angular/core */ 3499);
var _staticBlock;




const CHECK_STORAGE_KEY = 'process_check_snapshot_v1';
const RESULT_STORAGE_KEY = 'process_check_uploaded_result_v1';
class GenerateReportComponent {
  constructor() {
    this.router = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_angular_router__WEBPACK_IMPORTED_MODULE_2__.Router);
    this.processSnapshot = null;
    this.uploadedResult = null;
    this.completedChecks = 0;
    this.totalChecks = 0;
    this.refresh();
  }
  refresh() {
    this.processSnapshot = this.loadJson(CHECK_STORAGE_KEY);
    this.uploadedResult = this.loadJson(RESULT_STORAGE_KEY);
    const checks = this.processSnapshot?.checks ?? [];
    this.totalChecks = checks.length;
    this.completedChecks = checks.filter(check => check.status === 'completed').length;
  }
  readinessRatio() {
    if (this.totalChecks === 0) {
      return 0;
    }
    return Math.round(this.completedChecks / this.totalChecks * 100);
  }
  reportPreview() {
    return JSON.stringify(this.buildPayload(), null, 2);
  }
  downloadReport() {
    const payload = this.buildPayload();
    const blob = new Blob([JSON.stringify(payload, null, 2)], {
      type: 'application/json'
    });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = `process-check-report-${new Date().toISOString().slice(0, 10)}.json`;
    anchor.click();
    URL.revokeObjectURL(url);
  }
  go(path) {
    void this.router.navigateByUrl(path);
  }
  loadJson(storageKey) {
    if (typeof window === 'undefined') {
      return null;
    }
    const raw = window.localStorage.getItem(storageKey);
    if (!raw) {
      return null;
    }
    try {
      return JSON.parse(raw);
    } catch {
      return null;
    }
  }
  buildPayload() {
    return {
      generated_at: new Date().toISOString(),
      process_checks: this.processSnapshot,
      uploaded_result: this.uploadedResult,
      summary: {
        completed_checks: this.completedChecks,
        total_checks: this.totalChecks,
        readiness_ratio: this.readinessRatio()
      }
    };
  }
  static #_ = _staticBlock = () => (this.ɵfac = function GenerateReportComponent_Factory(__ngFactoryType__) {
    return new (__ngFactoryType__ || GenerateReportComponent)();
  }, this.ɵcmp = /*@__PURE__*/_angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdefineComponent"]({
    type: GenerateReportComponent,
    selectors: [["app-generate-report"]],
    decls: 44,
    vars: 5,
    consts: [[1, "page"], [1, "header-row"], ["level", "H2"], [1, "subtitle"], ["design", "Transparent", "icon", "refresh", 3, "click"], ["slot", "header", "title-text", "Assessment Summary"], [1, "content"], [1, "summary-row"], [1, "actions"], ["design", "Transparent", "icon", "navigation-left-arrow", 3, "click"], ["design", "Transparent", "icon", "machine", 3, "click"], ["design", "Emphasized", "icon", "download", 3, "click"], ["slot", "header", "title-text", "Report Preview"]],
    template: function GenerateReportComponent_Template(rf, ctx) {
      if (rf & 1) {
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](0, "section", 0)(1, "div", 1)(2, "div")(3, "ui5-title", 2);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](4, "Generate Report");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](5, "p", 3);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](6, "Create a consolidated JSON report from process checks and test results.");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](7, "ui5-button", 4);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomListener"]("click", function GenerateReportComponent_Template_ui5_button_click_7_listener() {
          return ctx.refresh();
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](8, "Refresh");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](9, "ui5-card");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElement"](10, "ui5-card-header", 5);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](11, "div", 6)(12, "div", 7)(13, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](14, "Completed checks");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](15, "strong");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](16);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](17, "div", 7)(18, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](19, "Total checks");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](20, "strong");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](21);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](22, "div", 7)(23, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](24, "Readiness ratio");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](25, "strong");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](26);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](27, "div", 7)(28, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](29, "Uploaded run");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](30, "strong");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](31);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](32, "div", 8)(33, "ui5-button", 9);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomListener"]("click", function GenerateReportComponent_Template_ui5_button_click_33_listener() {
          return ctx.go("/upload-results");
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](34, "Back");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](35, "ui5-button", 10);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomListener"]("click", function GenerateReportComponent_Template_ui5_button_click_35_listener() {
          return ctx.go("/history");
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](36, "Open Run History");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](37, "ui5-button", 11);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomListener"]("click", function GenerateReportComponent_Template_ui5_button_click_37_listener() {
          return ctx.downloadReport();
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](38, "Download Report JSON");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]()()()();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](39, "ui5-card");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElement"](40, "ui5-card-header", 12);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](41, "div", 6)(42, "pre");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](43);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]()()()();
      }
      if (rf & 2) {
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](16);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate"](ctx.completedChecks);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](5);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate"](ctx.totalChecks);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](5);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate1"]("", ctx.readinessRatio(), "%");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](5);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate"]((ctx.uploadedResult == null ? null : ctx.uploadedResult.run_id) ?? "none");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](12);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate"](ctx.reportPreview());
      }
    },
    dependencies: [_angular_common__WEBPACK_IMPORTED_MODULE_0__.CommonModule],
    styles: [".page[_ngcontent-%COMP%] {\n  display: grid;\n  gap: 0.9rem;\n}\n\n.header-row[_ngcontent-%COMP%] {\n  display: flex;\n  justify-content: space-between;\n  gap: 1rem;\n}\n\n.subtitle[_ngcontent-%COMP%] {\n  margin: 0.35rem 0 0;\n  color: var(--sapContent_LabelColor);\n}\n\n.content[_ngcontent-%COMP%] {\n  padding: 0.9rem;\n}\n\n.summary-row[_ngcontent-%COMP%] {\n  display: flex;\n  justify-content: space-between;\n  gap: 1rem;\n  margin-bottom: 0.5rem;\n}\n\n.actions[_ngcontent-%COMP%] {\n  margin-top: 0.8rem;\n  display: flex;\n  gap: 0.5rem;\n  flex-wrap: wrap;\n}\n\npre[_ngcontent-%COMP%] {\n  margin: 0;\n  white-space: pre-wrap;\n  word-break: break-word;\n}\n\n@media (max-width: 760px) {\n  .header-row[_ngcontent-%COMP%] {\n    flex-direction: column;\n  }\n}\n/*# sourceMappingURL=data:application/json;charset=utf-8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIndlYnBhY2s6Ly8uL2FwcHMvbW9vbnNob3QtY29uc29sZS9zcmMvYXBwL2ZlYXR1cmVzL2dlbmVyYXRlLXJlcG9ydC9nZW5lcmF0ZS1yZXBvcnQuY29tcG9uZW50LnRzIl0sIm5hbWVzIjpbXSwibWFwcGluZ3MiOiJBQUNNO0VBQ0UsYUFBQTtFQUNBLFdBQUE7QUFBUjs7QUFHTTtFQUNFLGFBQUE7RUFDQSw4QkFBQTtFQUNBLFNBQUE7QUFBUjs7QUFHTTtFQUNFLG1CQUFBO0VBQ0EsbUNBQUE7QUFBUjs7QUFHTTtFQUNFLGVBQUE7QUFBUjs7QUFHTTtFQUNFLGFBQUE7RUFDQSw4QkFBQTtFQUNBLFNBQUE7RUFDQSxxQkFBQTtBQUFSOztBQUdNO0VBQ0Usa0JBQUE7RUFDQSxhQUFBO0VBQ0EsV0FBQTtFQUNBLGVBQUE7QUFBUjs7QUFHTTtFQUNFLFNBQUE7RUFDQSxxQkFBQTtFQUNBLHNCQUFBO0FBQVI7O0FBR007RUFDRTtJQUNFLHNCQUFBO0VBQVI7QUFDRiIsInNvdXJjZXNDb250ZW50IjpbIlxuICAgICAgLnBhZ2Uge1xuICAgICAgICBkaXNwbGF5OiBncmlkO1xuICAgICAgICBnYXA6IDAuOXJlbTtcbiAgICAgIH1cblxuICAgICAgLmhlYWRlci1yb3cge1xuICAgICAgICBkaXNwbGF5OiBmbGV4O1xuICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47XG4gICAgICAgIGdhcDogMXJlbTtcbiAgICAgIH1cblxuICAgICAgLnN1YnRpdGxlIHtcbiAgICAgICAgbWFyZ2luOiAwLjM1cmVtIDAgMDtcbiAgICAgICAgY29sb3I6IHZhcigtLXNhcENvbnRlbnRfTGFiZWxDb2xvcik7XG4gICAgICB9XG5cbiAgICAgIC5jb250ZW50IHtcbiAgICAgICAgcGFkZGluZzogMC45cmVtO1xuICAgICAgfVxuXG4gICAgICAuc3VtbWFyeS1yb3cge1xuICAgICAgICBkaXNwbGF5OiBmbGV4O1xuICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47XG4gICAgICAgIGdhcDogMXJlbTtcbiAgICAgICAgbWFyZ2luLWJvdHRvbTogMC41cmVtO1xuICAgICAgfVxuXG4gICAgICAuYWN0aW9ucyB7XG4gICAgICAgIG1hcmdpbi10b3A6IDAuOHJlbTtcbiAgICAgICAgZGlzcGxheTogZmxleDtcbiAgICAgICAgZ2FwOiAwLjVyZW07XG4gICAgICAgIGZsZXgtd3JhcDogd3JhcDtcbiAgICAgIH1cblxuICAgICAgcHJlIHtcbiAgICAgICAgbWFyZ2luOiAwO1xuICAgICAgICB3aGl0ZS1zcGFjZTogcHJlLXdyYXA7XG4gICAgICAgIHdvcmQtYnJlYWs6IGJyZWFrLXdvcmQ7XG4gICAgICB9XG5cbiAgICAgIEBtZWRpYSAobWF4LXdpZHRoOiA3NjBweCkge1xuICAgICAgICAuaGVhZGVyLXJvdyB7XG4gICAgICAgICAgZmxleC1kaXJlY3Rpb246IGNvbHVtbjtcbiAgICAgICAgfVxuICAgICAgfVxuICAgICJdLCJzb3VyY2VSb290IjoiIn0= */"]
  }));
}
_staticBlock();

/***/ })

}]);
//# sourceMappingURL=apps_moonshot-console_src_app_features_generate-report_generate-report_component_ts.js.map