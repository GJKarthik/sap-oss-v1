"use strict";
(self["webpackChunkmoonshot_console"] = self["webpackChunkmoonshot_console"] || []).push([["apps_moonshot-console_src_app_features_process-checks_process-checks_component_ts"],{

/***/ 9155:
/*!*******************************************************************************************!*\
  !*** ./apps/moonshot-console/src/app/features/process-checks/process-checks.component.ts ***!
  \*******************************************************************************************/
/***/ ((__unused_webpack_module, __webpack_exports__, __webpack_require__) => {

__webpack_require__.r(__webpack_exports__);
/* harmony export */ __webpack_require__.d(__webpack_exports__, {
/* harmony export */   ProcessChecksComponent: () => (/* binding */ ProcessChecksComponent)
/* harmony export */ });
/* harmony import */ var _angular_common__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! @angular/common */ 7737);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! @angular/core */ 4131);
/* harmony import */ var _angular_router__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! @angular/router */ 3288);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! @angular/core */ 3499);
var _staticBlock;





function ProcessChecksComponent_ui5_card_15_Template(rf, ctx) {
  if (rf & 1) {
    const _r1 = _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵgetCurrentView"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](0, "ui5-card");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelement"](1, "ui5-card-header", 13);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](2, "div", 14)(3, "label", 15)(4, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](5, "Status");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](6, "ui5-select", 16);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("change", function ProcessChecksComponent_ui5_card_15_Template_ui5_select_change_6_listener($event) {
      const check_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵrestoreView"](_r1).$implicit;
      const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵnextContext"]();
      return _angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵresetView"](ctx_r2.setStatusFromEvent(check_r2.id, $event));
    });
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](7, "ui5-option", 17);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](8, "Not Started");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](9, "ui5-option", 18);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](10, "In Progress");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](11, "ui5-option", 19);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](12, "Completed");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()()();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](13, "label", 15)(14, "span");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](15, "Notes");
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](16, "ui5-textarea", 20);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("input", function ProcessChecksComponent_ui5_card_15_Template_ui5_textarea_input_16_listener($event) {
      const check_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵrestoreView"](_r1).$implicit;
      const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵnextContext"]();
      return _angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵresetView"](ctx_r2.setNotes(check_r2.id, ctx_r2.valueFromEvent($event)));
    });
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()()()();
  }
  if (rf & 2) {
    const check_r2 = ctx.$implicit;
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵproperty"]("title-text", check_r2.title);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](5);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵproperty"]("value", check_r2.status);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](10);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵproperty"]("value", check_r2.notes);
  }
}
const STORAGE_KEY = 'process_check_snapshot_v1';
class ProcessChecksComponent {
  constructor() {
    this.router = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_angular_router__WEBPACK_IMPORTED_MODULE_2__.Router);
    this.checks = this.loadSnapshot();
  }
  valueFromEvent(event) {
    const target = event.target;
    return target.value ?? '';
  }
  setStatus(id, status) {
    this.checks = this.checks.map(check => check.id === id ? {
      ...check,
      status
    } : check);
    this.persist();
  }
  setStatusFromEvent(id, event) {
    const raw = this.valueFromEvent(event);
    const status = raw === 'completed' || raw === 'in_progress' || raw === 'not_started' ? raw : 'not_started';
    this.setStatus(id, status);
  }
  setNotes(id, notes) {
    this.checks = this.checks.map(check => check.id === id ? {
      ...check,
      notes
    } : check);
    this.persist();
  }
  completedCount() {
    return this.checks.filter(check => check.status === 'completed').length;
  }
  reset() {
    this.checks = this.defaultChecks();
    this.persist();
  }
  downloadSnapshot() {
    const payload = {
      updated_at: new Date().toISOString(),
      checks: this.checks
    };
    const blob = new Blob([JSON.stringify(payload, null, 2)], {
      type: 'application/json'
    });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = 'process-checks.json';
    anchor.click();
    URL.revokeObjectURL(url);
  }
  go(path) {
    void this.router.navigateByUrl(path);
  }
  persist() {
    if (typeof window === 'undefined') {
      return;
    }
    const payload = {
      updated_at: new Date().toISOString(),
      checks: this.checks
    };
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
  }
  loadSnapshot() {
    if (typeof window === 'undefined') {
      return this.defaultChecks();
    }
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      return this.defaultChecks();
    }
    try {
      const parsed = JSON.parse(raw);
      if (!Array.isArray(parsed.checks)) {
        return this.defaultChecks();
      }
      return parsed.checks.map(check => ({
        id: check.id,
        title: check.title,
        status: check.status,
        notes: check.notes ?? ''
      }));
    } catch {
      return this.defaultChecks();
    }
  }
  defaultChecks() {
    return [{
      id: 'transparency',
      title: 'Transparency',
      status: 'not_started',
      notes: ''
    }, {
      id: 'explainability',
      title: 'Explainability',
      status: 'not_started',
      notes: ''
    }, {
      id: 'reproducibility',
      title: 'Reproducibility',
      status: 'not_started',
      notes: ''
    }, {
      id: 'safety',
      title: 'Safety',
      status: 'not_started',
      notes: ''
    }, {
      id: 'security',
      title: 'Security',
      status: 'not_started',
      notes: ''
    }, {
      id: 'robustness',
      title: 'Robustness',
      status: 'not_started',
      notes: ''
    }, {
      id: 'fairness',
      title: 'Fairness',
      status: 'not_started',
      notes: ''
    }, {
      id: 'data_governance',
      title: 'Data Governance',
      status: 'not_started',
      notes: ''
    }, {
      id: 'accountability',
      title: 'Accountability',
      status: 'not_started',
      notes: ''
    }, {
      id: 'human_agency',
      title: 'Human Agency and Oversight',
      status: 'not_started',
      notes: ''
    }, {
      id: 'inclusive_growth',
      title: 'Inclusive Growth and Well-being',
      status: 'not_started',
      notes: ''
    }];
  }
  static #_ = _staticBlock = () => (this.ɵfac = function ProcessChecksComponent_Factory(__ngFactoryType__) {
    return new (__ngFactoryType__ || ProcessChecksComponent)();
  }, this.ɵcmp = /*@__PURE__*/_angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdefineComponent"]({
    type: ProcessChecksComponent,
    selectors: [["app-process-checks"]],
    decls: 21,
    vars: 3,
    consts: [[1, "page"], [1, "header-row"], ["level", "H2"], [1, "subtitle"], [1, "header-actions"], ["design", "Transparent", "icon", "download", 3, "click"], ["design", "Transparent", "icon", "refresh", 3, "click"], ["design", "Information", "hide-close-button", ""], [1, "grid"], [4, "ngFor", "ngForOf"], [1, "footer-actions"], ["design", "Transparent", "icon", "navigation-left-arrow", 3, "click"], ["design", "Emphasized", "icon", "navigation-right-arrow", 3, "click"], ["slot", "header", 3, "title-text"], [1, "card-content"], [1, "field"], [3, "change", "value"], ["value", "not_started"], ["value", "in_progress"], ["value", "completed"], ["growing", "", "growing-max-lines", "6", "placeholder", "Evidence, links, controls, policy references", 3, "input", "value"]],
    template: function ProcessChecksComponent_Template(rf, ctx) {
      if (rf & 1) {
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](0, "section", 0)(1, "div", 1)(2, "div")(3, "ui5-title", 2);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](4, "Process Checks");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](5, "p", 3);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](6, "Track governance implementation status across the AI Verify principles.");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](7, "div", 4)(8, "ui5-button", 5);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("click", function ProcessChecksComponent_Template_ui5_button_click_8_listener() {
          return ctx.downloadSnapshot();
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](9, "Export");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](10, "ui5-button", 6);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("click", function ProcessChecksComponent_Template_ui5_button_click_10_listener() {
          return ctx.reset();
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](11, "Reset");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()()();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](12, "ui5-message-strip", 7);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](13);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](14, "div", 8);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtemplate"](15, ProcessChecksComponent_ui5_card_15_Template, 17, 3, "ui5-card", 9);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](16, "div", 10)(17, "ui5-button", 11);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("click", function ProcessChecksComponent_Template_ui5_button_click_17_listener() {
          return ctx.go("/getting-started");
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](18, "Back");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](19, "ui5-button", 12);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("click", function ProcessChecksComponent_Template_ui5_button_click_19_listener() {
          return ctx.go("/upload-results");
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](20, " Continue ");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()()();
      }
      if (rf & 2) {
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](13);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate2"](" Completed ", ctx.completedCount(), " / ", ctx.checks.length, " checks ");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](2);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵproperty"]("ngForOf", ctx.checks);
      }
    },
    dependencies: [_angular_common__WEBPACK_IMPORTED_MODULE_0__.CommonModule, _angular_common__WEBPACK_IMPORTED_MODULE_0__.NgForOf],
    styles: [".page[_ngcontent-%COMP%] {\n  display: grid;\n  gap: 0.8rem;\n}\n\n.header-row[_ngcontent-%COMP%] {\n  display: flex;\n  justify-content: space-between;\n  gap: 1rem;\n  align-items: flex-start;\n}\n\n.subtitle[_ngcontent-%COMP%] {\n  margin: 0.35rem 0 0;\n  color: var(--sapContent_LabelColor);\n}\n\n.header-actions[_ngcontent-%COMP%] {\n  display: flex;\n  gap: 0.5rem;\n}\n\n.grid[_ngcontent-%COMP%] {\n  display: grid;\n  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));\n  gap: 0.8rem;\n}\n\n.card-content[_ngcontent-%COMP%] {\n  padding: 0.8rem;\n  display: grid;\n  gap: 0.7rem;\n}\n\n.field[_ngcontent-%COMP%] {\n  display: grid;\n  gap: 0.3rem;\n}\n\n.field[_ngcontent-%COMP%]   span[_ngcontent-%COMP%] {\n  font-size: 0.78rem;\n  color: var(--sapContent_LabelColor);\n}\n\n.footer-actions[_ngcontent-%COMP%] {\n  display: flex;\n  justify-content: space-between;\n}\n\n@media (max-width: 760px) {\n  .header-row[_ngcontent-%COMP%] {\n    flex-direction: column;\n  }\n}\n/*# sourceMappingURL=data:application/json;charset=utf-8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIndlYnBhY2s6Ly8uL2FwcHMvbW9vbnNob3QtY29uc29sZS9zcmMvYXBwL2ZlYXR1cmVzL3Byb2Nlc3MtY2hlY2tzL3Byb2Nlc3MtY2hlY2tzLmNvbXBvbmVudC50cyJdLCJuYW1lcyI6W10sIm1hcHBpbmdzIjoiQUFDTTtFQUNFLGFBQUE7RUFDQSxXQUFBO0FBQVI7O0FBR007RUFDRSxhQUFBO0VBQ0EsOEJBQUE7RUFDQSxTQUFBO0VBQ0EsdUJBQUE7QUFBUjs7QUFHTTtFQUNFLG1CQUFBO0VBQ0EsbUNBQUE7QUFBUjs7QUFHTTtFQUNFLGFBQUE7RUFDQSxXQUFBO0FBQVI7O0FBR007RUFDRSxhQUFBO0VBQ0EsMkRBQUE7RUFDQSxXQUFBO0FBQVI7O0FBR007RUFDRSxlQUFBO0VBQ0EsYUFBQTtFQUNBLFdBQUE7QUFBUjs7QUFHTTtFQUNFLGFBQUE7RUFDQSxXQUFBO0FBQVI7O0FBR007RUFDRSxrQkFBQTtFQUNBLG1DQUFBO0FBQVI7O0FBR007RUFDRSxhQUFBO0VBQ0EsOEJBQUE7QUFBUjs7QUFHTTtFQUNFO0lBQ0Usc0JBQUE7RUFBUjtBQUNGIiwic291cmNlc0NvbnRlbnQiOlsiXG4gICAgICAucGFnZSB7XG4gICAgICAgIGRpc3BsYXk6IGdyaWQ7XG4gICAgICAgIGdhcDogMC44cmVtO1xuICAgICAgfVxuXG4gICAgICAuaGVhZGVyLXJvdyB7XG4gICAgICAgIGRpc3BsYXk6IGZsZXg7XG4gICAgICAgIGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjtcbiAgICAgICAgZ2FwOiAxcmVtO1xuICAgICAgICBhbGlnbi1pdGVtczogZmxleC1zdGFydDtcbiAgICAgIH1cblxuICAgICAgLnN1YnRpdGxlIHtcbiAgICAgICAgbWFyZ2luOiAwLjM1cmVtIDAgMDtcbiAgICAgICAgY29sb3I6IHZhcigtLXNhcENvbnRlbnRfTGFiZWxDb2xvcik7XG4gICAgICB9XG5cbiAgICAgIC5oZWFkZXItYWN0aW9ucyB7XG4gICAgICAgIGRpc3BsYXk6IGZsZXg7XG4gICAgICAgIGdhcDogMC41cmVtO1xuICAgICAgfVxuXG4gICAgICAuZ3JpZCB7XG4gICAgICAgIGRpc3BsYXk6IGdyaWQ7XG4gICAgICAgIGdyaWQtdGVtcGxhdGUtY29sdW1uczogcmVwZWF0KGF1dG8tZml0LCBtaW5tYXgoMzAwcHgsIDFmcikpO1xuICAgICAgICBnYXA6IDAuOHJlbTtcbiAgICAgIH1cblxuICAgICAgLmNhcmQtY29udGVudCB7XG4gICAgICAgIHBhZGRpbmc6IDAuOHJlbTtcbiAgICAgICAgZGlzcGxheTogZ3JpZDtcbiAgICAgICAgZ2FwOiAwLjdyZW07XG4gICAgICB9XG5cbiAgICAgIC5maWVsZCB7XG4gICAgICAgIGRpc3BsYXk6IGdyaWQ7XG4gICAgICAgIGdhcDogMC4zcmVtO1xuICAgICAgfVxuXG4gICAgICAuZmllbGQgc3BhbiB7XG4gICAgICAgIGZvbnQtc2l6ZTogMC43OHJlbTtcbiAgICAgICAgY29sb3I6IHZhcigtLXNhcENvbnRlbnRfTGFiZWxDb2xvcik7XG4gICAgICB9XG5cbiAgICAgIC5mb290ZXItYWN0aW9ucyB7XG4gICAgICAgIGRpc3BsYXk6IGZsZXg7XG4gICAgICAgIGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjtcbiAgICAgIH1cblxuICAgICAgQG1lZGlhIChtYXgtd2lkdGg6IDc2MHB4KSB7XG4gICAgICAgIC5oZWFkZXItcm93IHtcbiAgICAgICAgICBmbGV4LWRpcmVjdGlvbjogY29sdW1uO1xuICAgICAgICB9XG4gICAgICB9XG4gICAgIl0sInNvdXJjZVJvb3QiOiIifQ== */"]
  }));
}
_staticBlock();

/***/ })

}]);
//# sourceMappingURL=apps_moonshot-console_src_app_features_process-checks_process-checks_component_ts.js.map