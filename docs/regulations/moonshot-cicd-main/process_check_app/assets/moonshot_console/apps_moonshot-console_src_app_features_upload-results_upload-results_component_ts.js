"use strict";
(self["webpackChunkmoonshot_console"] = self["webpackChunkmoonshot_console"] || []).push([["apps_moonshot-console_src_app_features_upload-results_upload-results_component_ts"],{

/***/ 6953:
/*!*******************************************************************************************!*\
  !*** ./apps/moonshot-console/src/app/features/upload-results/upload-results.component.ts ***!
  \*******************************************************************************************/
/***/ ((__unused_webpack_module, __webpack_exports__, __webpack_require__) => {

__webpack_require__.r(__webpack_exports__);
/* harmony export */ __webpack_require__.d(__webpack_exports__, {
/* harmony export */   UploadResultsComponent: () => (/* binding */ UploadResultsComponent)
/* harmony export */ });
/* harmony import */ var _angular_common__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! @angular/common */ 7737);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! @angular/core */ 4131);
/* harmony import */ var _angular_router__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! @angular/router */ 3288);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! @angular/core */ 3499);
var _staticBlock;





function UploadResultsComponent_ui5_message_strip_9_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](0, "ui5-message-strip", 13);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](1);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const ctx_r0 = _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵnextContext"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate"](ctx_r0.errorMessage);
  }
}
function UploadResultsComponent_ui5_message_strip_10_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](0, "ui5-message-strip", 14);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](1);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const ctx_r0 = _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵnextContext"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate"](ctx_r0.successMessage);
  }
}
function UploadResultsComponent_ui5_card_11_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](0, "ui5-card");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelement"](1, "ui5-card-header", 15);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](2, "div", 16)(3, "div", 17)(4, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](5, "file");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](6, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](7);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](8, "div", 17)(9, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](10, "run_id");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](11, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](12);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](13, "div", 17)(14, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](15, "test_id");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](16, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](17);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](18, "div", 17)(19, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](20, "connector");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](21, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](22);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](23, "div", 17)(24, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](25, "tests_executed");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](26, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](27);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](28, "div", 17)(29, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](30, "dry_run_prompts");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](31, "strong");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](32);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()()()();
  }
  if (rf & 2) {
    const ctx_r0 = _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵnextContext"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](7);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate"](ctx_r0.summary.filename);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate"](ctx_r0.summary.run_id);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate"](ctx_r0.summary.test_id);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate"](ctx_r0.summary.connector);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate"](ctx_r0.summary.tests_executed);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate"](ctx_r0.summary.dry_run_prompts);
  }
}
const STORAGE_KEY = 'process_check_uploaded_result_v1';
class UploadResultsComponent {
  constructor() {
    this.router = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_angular_router__WEBPACK_IMPORTED_MODULE_2__.Router);
    this.summary = this.loadSummary();
    this.errorMessage = '';
    this.successMessage = '';
  }
  onFileSelected(event) {
    this.errorMessage = '';
    this.successMessage = '';
    const input = event.target;
    const file = input.files?.[0];
    if (!file) {
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      const content = typeof reader.result === 'string' ? reader.result : '';
      if (!content) {
        this.errorMessage = 'Selected file is empty.';
        return;
      }
      try {
        const parsed = JSON.parse(content);
        const runMetadata = parsed.run_metadata ?? {};
        const runResults = Array.isArray(parsed.run_results) ? parsed.run_results : [];
        const dryRunPrompts = runResults.reduce((total, item) => total + (item.dry_run_prompts ?? 0), 0);
        this.summary = {
          filename: file.name,
          run_id: runMetadata.run_id ?? 'unknown',
          test_id: runMetadata.test_id ?? 'unknown',
          connector: runMetadata.connector ?? 'unknown',
          tests_executed: runResults.length,
          dry_run_prompts: dryRunPrompts,
          imported_at: new Date().toISOString()
        };
        this.persistSummary();
        this.successMessage = 'Result file imported successfully.';
      } catch {
        this.errorMessage = 'Invalid JSON file. Please upload a Moonshot result JSON.';
      }
    };
    reader.onerror = () => {
      this.errorMessage = 'Failed to read file.';
    };
    reader.readAsText(file);
  }
  go(path) {
    void this.router.navigateByUrl(path);
  }
  persistSummary() {
    if (typeof window === 'undefined' || !this.summary) {
      return;
    }
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(this.summary));
  }
  loadSummary() {
    if (typeof window === 'undefined') {
      return null;
    }
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      return null;
    }
    try {
      return JSON.parse(raw);
    } catch {
      return null;
    }
  }
  static #_ = _staticBlock = () => (this.ɵfac = function UploadResultsComponent_Factory(__ngFactoryType__) {
    return new (__ngFactoryType__ || UploadResultsComponent)();
  }, this.ɵcmp = /*@__PURE__*/_angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdefineComponent"]({
    type: UploadResultsComponent,
    selectors: [["app-upload-results"]],
    decls: 19,
    vars: 4,
    consts: [[1, "page"], ["slot", "header", "title-text", "Upload Technical Test Results", "subtitle-text", "Import Moonshot JSON output"], ["slot", "avatar", "name", "upload"], [1, "content"], [1, "upload-box"], ["type", "file", "accept", "application/json,.json", 3, "change"], ["design", "Negative", 4, "ngIf"], ["design", "Positive", 4, "ngIf"], [4, "ngIf"], [1, "actions"], ["design", "Transparent", "icon", "navigation-left-arrow", 3, "click"], ["design", "Transparent", "icon", "media-play", 3, "click"], ["design", "Emphasized", "icon", "navigation-right-arrow", 3, "click", "disabled"], ["design", "Negative"], ["design", "Positive"], ["slot", "header", "title-text", "Imported Summary"], [1, "summary"], [1, "row"]],
    template: function UploadResultsComponent_Template(rf, ctx) {
      if (rf & 1) {
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](0, "section", 0)(1, "ui5-card")(2, "ui5-card-header", 1);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelement"](3, "ui5-icon", 2);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](4, "div", 3)(5, "label", 4)(6, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](7, "Select Moonshot result file (.json)");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](8, "input", 5);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("change", function UploadResultsComponent_Template_input_change_8_listener($event) {
          return ctx.onFileSelected($event);
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtemplate"](9, UploadResultsComponent_ui5_message_strip_9_Template, 2, 1, "ui5-message-strip", 6)(10, UploadResultsComponent_ui5_message_strip_10_Template, 2, 1, "ui5-message-strip", 7)(11, UploadResultsComponent_ui5_card_11_Template, 33, 6, "ui5-card", 8);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](12, "div", 9)(13, "ui5-button", 10);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("click", function UploadResultsComponent_Template_ui5_button_click_13_listener() {
          return ctx.go("/process-checks");
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](14, "Back");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](15, "ui5-button", 11);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("click", function UploadResultsComponent_Template_ui5_button_click_15_listener() {
          return ctx.go("/runs");
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](16, "Trigger New Run");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](17, "ui5-button", 12);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("click", function UploadResultsComponent_Template_ui5_button_click_17_listener() {
          return ctx.go("/generate-report");
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](18, " Continue ");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()()()()();
      }
      if (rf & 2) {
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](9);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵproperty"]("ngIf", ctx.errorMessage);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵproperty"]("ngIf", ctx.successMessage);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵproperty"]("ngIf", ctx.summary);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](6);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵproperty"]("disabled", !ctx.summary);
      }
    },
    dependencies: [_angular_common__WEBPACK_IMPORTED_MODULE_0__.CommonModule, _angular_common__WEBPACK_IMPORTED_MODULE_0__.NgIf],
    styles: [".page[_ngcontent-%COMP%] {\n  display: grid;\n}\n\n.content[_ngcontent-%COMP%] {\n  padding: 1rem;\n  display: grid;\n  gap: 0.9rem;\n}\n\n.upload-box[_ngcontent-%COMP%] {\n  display: grid;\n  gap: 0.45rem;\n  padding: 0.85rem;\n  border: 1px dashed var(--moonshot-border);\n  border-radius: 8px;\n  background: var(--moonshot-panel);\n}\n\n.summary[_ngcontent-%COMP%] {\n  padding: 0.8rem;\n}\n\n.row[_ngcontent-%COMP%] {\n  display: flex;\n  justify-content: space-between;\n  gap: 1rem;\n  margin-bottom: 0.4rem;\n}\n\n.actions[_ngcontent-%COMP%] {\n  display: flex;\n  justify-content: space-between;\n  gap: 0.5rem;\n  flex-wrap: wrap;\n}\n/*# sourceMappingURL=data:application/json;charset=utf-8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIndlYnBhY2s6Ly8uL2FwcHMvbW9vbnNob3QtY29uc29sZS9zcmMvYXBwL2ZlYXR1cmVzL3VwbG9hZC1yZXN1bHRzL3VwbG9hZC1yZXN1bHRzLmNvbXBvbmVudC50cyJdLCJuYW1lcyI6W10sIm1hcHBpbmdzIjoiQUFDTTtFQUNFLGFBQUE7QUFBUjs7QUFHTTtFQUNFLGFBQUE7RUFDQSxhQUFBO0VBQ0EsV0FBQTtBQUFSOztBQUdNO0VBQ0UsYUFBQTtFQUNBLFlBQUE7RUFDQSxnQkFBQTtFQUNBLHlDQUFBO0VBQ0Esa0JBQUE7RUFDQSxpQ0FBQTtBQUFSOztBQUdNO0VBQ0UsZUFBQTtBQUFSOztBQUdNO0VBQ0UsYUFBQTtFQUNBLDhCQUFBO0VBQ0EsU0FBQTtFQUNBLHFCQUFBO0FBQVI7O0FBR007RUFDRSxhQUFBO0VBQ0EsOEJBQUE7RUFDQSxXQUFBO0VBQ0EsZUFBQTtBQUFSIiwic291cmNlc0NvbnRlbnQiOlsiXG4gICAgICAucGFnZSB7XG4gICAgICAgIGRpc3BsYXk6IGdyaWQ7XG4gICAgICB9XG5cbiAgICAgIC5jb250ZW50IHtcbiAgICAgICAgcGFkZGluZzogMXJlbTtcbiAgICAgICAgZGlzcGxheTogZ3JpZDtcbiAgICAgICAgZ2FwOiAwLjlyZW07XG4gICAgICB9XG5cbiAgICAgIC51cGxvYWQtYm94IHtcbiAgICAgICAgZGlzcGxheTogZ3JpZDtcbiAgICAgICAgZ2FwOiAwLjQ1cmVtO1xuICAgICAgICBwYWRkaW5nOiAwLjg1cmVtO1xuICAgICAgICBib3JkZXI6IDFweCBkYXNoZWQgdmFyKC0tbW9vbnNob3QtYm9yZGVyKTtcbiAgICAgICAgYm9yZGVyLXJhZGl1czogOHB4O1xuICAgICAgICBiYWNrZ3JvdW5kOiB2YXIoLS1tb29uc2hvdC1wYW5lbCk7XG4gICAgICB9XG5cbiAgICAgIC5zdW1tYXJ5IHtcbiAgICAgICAgcGFkZGluZzogMC44cmVtO1xuICAgICAgfVxuXG4gICAgICAucm93IHtcbiAgICAgICAgZGlzcGxheTogZmxleDtcbiAgICAgICAganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuO1xuICAgICAgICBnYXA6IDFyZW07XG4gICAgICAgIG1hcmdpbi1ib3R0b206IDAuNHJlbTtcbiAgICAgIH1cblxuICAgICAgLmFjdGlvbnMge1xuICAgICAgICBkaXNwbGF5OiBmbGV4O1xuICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47XG4gICAgICAgIGdhcDogMC41cmVtO1xuICAgICAgICBmbGV4LXdyYXA6IHdyYXA7XG4gICAgICB9XG4gICAgIl0sInNvdXJjZVJvb3QiOiIifQ== */"]
  }));
}
_staticBlock();

/***/ })

}]);
//# sourceMappingURL=apps_moonshot-console_src_app_features_upload-results_upload-results_component_ts.js.map