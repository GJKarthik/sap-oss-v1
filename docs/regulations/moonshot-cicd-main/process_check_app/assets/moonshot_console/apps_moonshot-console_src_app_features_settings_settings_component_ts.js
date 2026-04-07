"use strict";
(self["webpackChunkmoonshot_console"] = self["webpackChunkmoonshot_console"] || []).push([["apps_moonshot-console_src_app_features_settings_settings_component_ts"],{

/***/ 2031:
/*!*******************************************************************************!*\
  !*** ./apps/moonshot-console/src/app/features/settings/settings.component.ts ***!
  \*******************************************************************************/
/***/ ((__unused_webpack_module, __webpack_exports__, __webpack_require__) => {

__webpack_require__.r(__webpack_exports__);
/* harmony export */ __webpack_require__.d(__webpack_exports__, {
/* harmony export */   SettingsComponent: () => (/* binding */ SettingsComponent)
/* harmony export */ });
/* harmony import */ var _angular_common__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! @angular/common */ 7737);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! @angular/core */ 4131);
/* harmony import */ var _angular_core_rxjs_interop__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! @angular/core/rxjs-interop */ 5768);
/* harmony import */ var _core_services_moonshot_api_service__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! ../../core/services/moonshot-api.service */ 5509);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__(/*! @angular/core */ 3499);
var _staticBlock;






function SettingsComponent_ui5_message_strip_27_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "ui5-message-strip", 14);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](1);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const ctx_r0 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵnextContext"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("design", ctx_r0.messageDesign);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](ctx_r0.message);
  }
}
class SettingsComponent {
  constructor() {
    this.destroyRef = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_angular_core__WEBPACK_IMPORTED_MODULE_1__.DestroyRef);
    this.moonshot = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_core_services_moonshot_api_service__WEBPACK_IMPORTED_MODULE_3__.MoonshotApiService);
    this.baseUrl = this.moonshot.getConfig().baseUrl;
    this.timeoutMsText = String(this.moonshot.getConfig().timeoutMs);
    this.useMockFallback = this.moonshot.getConfig().useMockFallback;
    this.testing = false;
    this.message = '';
    this.messageDesign = 'Information';
  }
  save() {
    const timeout = Number.parseInt(this.timeoutMsText, 10);
    this.moonshot.setConfig({
      baseUrl: this.baseUrl.trim(),
      timeoutMs: Number.isFinite(timeout) ? timeout : 30000,
      useMockFallback: this.useMockFallback
    });
    this.message = 'Settings saved.';
    this.messageDesign = 'Positive';
  }
  testConnection() {
    this.testing = true;
    this.message = '';
    this.save();
    this.moonshot.checkHealth().pipe((0,_angular_core_rxjs_interop__WEBPACK_IMPORTED_MODULE_2__.takeUntilDestroyed)(this.destroyRef)).subscribe({
      next: health => {
        this.testing = false;
        if (health.status === 'ok') {
          this.message = 'Connection test succeeded.';
          this.messageDesign = 'Positive';
        } else {
          this.message = 'Connection test returned a non-ok status.';
          this.messageDesign = 'Warning';
        }
      },
      error: error => {
        this.testing = false;
        this.message = error.message;
        this.messageDesign = 'Negative';
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
  static #_ = _staticBlock = () => (this.ɵfac = function SettingsComponent_Factory(__ngFactoryType__) {
    return new (__ngFactoryType__ || SettingsComponent)();
  }, this.ɵcmp = /*@__PURE__*/_angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵdefineComponent"]({
    type: SettingsComponent,
    selectors: [["app-settings"]],
    decls: 28,
    vars: 6,
    consts: [[1, "page"], ["level", "H2"], [1, "subtitle"], ["slot", "header", "title-text", "Moonshot Backend"], [1, "card-content", "form-grid"], [1, "field"], ["placeholder", "http://localhost:8088", 3, "input", "value"], ["type", "Number", 3, "input", "value"], [1, "field", "inline"], [3, "change", "checked"], [1, "actions"], ["design", "Emphasized", "icon", "save", 3, "click"], ["design", "Transparent", "icon", "connected", 3, "click", "disabled"], [3, "design", 4, "ngIf"], [3, "design"]],
    template: function SettingsComponent_Template(rf, ctx) {
      if (rf & 1) {
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "section", 0)(1, "div")(2, "ui5-title", 1);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](3, "Settings");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](4, "p", 2);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](5, "Configure backend URL and offline behavior.");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](6, "ui5-card");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelement"](7, "ui5-card-header", 3);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](8, "div", 4)(9, "label", 5)(10, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](11, "Backend URL");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](12, "ui5-input", 6);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵlistener"]("input", function SettingsComponent_Template_ui5_input_input_12_listener($event) {
          return ctx.baseUrl = ctx.valueFromEvent($event);
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](13, "label", 5)(14, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](15, "Timeout (ms)");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](16, "ui5-input", 7);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵlistener"]("input", function SettingsComponent_Template_ui5_input_input_16_listener($event) {
          return ctx.timeoutMsText = ctx.valueFromEvent($event);
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](17, "label", 8)(18, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](19, "Mock fallback");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](20, "ui5-checkbox", 9);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵlistener"]("change", function SettingsComponent_Template_ui5_checkbox_change_20_listener($event) {
          return ctx.useMockFallback = ctx.checkedFromEvent($event);
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](21, " Enable mocked responses when backend is unavailable ");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](22, "div", 10)(23, "ui5-button", 11);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵlistener"]("click", function SettingsComponent_Template_ui5_button_click_23_listener() {
          return ctx.save();
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](24, "Save");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](25, "ui5-button", 12);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵlistener"]("click", function SettingsComponent_Template_ui5_button_click_25_listener() {
          return ctx.testConnection();
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](26);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](27, SettingsComponent_ui5_message_strip_27_Template, 2, 2, "ui5-message-strip", 13);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
      }
      if (rf & 2) {
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](12);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("value", ctx.baseUrl);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](4);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("value", ctx.timeoutMsText);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](4);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("checked", ctx.useMockFallback);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](5);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("disabled", ctx.testing);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate1"](" ", ctx.testing ? "Testing..." : "Test Connection", " ");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngIf", ctx.message);
      }
    },
    dependencies: [_angular_common__WEBPACK_IMPORTED_MODULE_0__.CommonModule, _angular_common__WEBPACK_IMPORTED_MODULE_0__.NgIf],
    styles: [".page[_ngcontent-%COMP%] {\n  display: grid;\n  gap: 1rem;\n}\n\n.subtitle[_ngcontent-%COMP%] {\n  margin: 0.4rem 0 0;\n  color: var(--sapContent_LabelColor);\n}\n\n.card-content[_ngcontent-%COMP%] {\n  padding: 1rem;\n}\n\n.form-grid[_ngcontent-%COMP%] {\n  display: grid;\n  grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));\n  gap: 0.9rem;\n}\n\n.field[_ngcontent-%COMP%] {\n  display: grid;\n  gap: 0.35rem;\n}\n\n.field[_ngcontent-%COMP%]   span[_ngcontent-%COMP%] {\n  color: var(--sapContent_LabelColor);\n  font-size: 0.78rem;\n}\n\n.inline[_ngcontent-%COMP%] {\n  align-items: end;\n}\n\n.actions[_ngcontent-%COMP%] {\n  padding: 0 1rem 1rem;\n  display: flex;\n  gap: 0.5rem;\n}\n/*# sourceMappingURL=data:application/json;charset=utf-8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIndlYnBhY2s6Ly8uL2FwcHMvbW9vbnNob3QtY29uc29sZS9zcmMvYXBwL2ZlYXR1cmVzL3NldHRpbmdzL3NldHRpbmdzLmNvbXBvbmVudC50cyJdLCJuYW1lcyI6W10sIm1hcHBpbmdzIjoiQUFDTTtFQUNFLGFBQUE7RUFDQSxTQUFBO0FBQVI7O0FBR007RUFDRSxrQkFBQTtFQUNBLG1DQUFBO0FBQVI7O0FBR007RUFDRSxhQUFBO0FBQVI7O0FBR007RUFDRSxhQUFBO0VBQ0EsMkRBQUE7RUFDQSxXQUFBO0FBQVI7O0FBR007RUFDRSxhQUFBO0VBQ0EsWUFBQTtBQUFSOztBQUdNO0VBQ0UsbUNBQUE7RUFDQSxrQkFBQTtBQUFSOztBQUdNO0VBQ0UsZ0JBQUE7QUFBUjs7QUFHTTtFQUNFLG9CQUFBO0VBQ0EsYUFBQTtFQUNBLFdBQUE7QUFBUiIsInNvdXJjZXNDb250ZW50IjpbIlxuICAgICAgLnBhZ2Uge1xuICAgICAgICBkaXNwbGF5OiBncmlkO1xuICAgICAgICBnYXA6IDFyZW07XG4gICAgICB9XG5cbiAgICAgIC5zdWJ0aXRsZSB7XG4gICAgICAgIG1hcmdpbjogMC40cmVtIDAgMDtcbiAgICAgICAgY29sb3I6IHZhcigtLXNhcENvbnRlbnRfTGFiZWxDb2xvcik7XG4gICAgICB9XG5cbiAgICAgIC5jYXJkLWNvbnRlbnQge1xuICAgICAgICBwYWRkaW5nOiAxcmVtO1xuICAgICAgfVxuXG4gICAgICAuZm9ybS1ncmlkIHtcbiAgICAgICAgZGlzcGxheTogZ3JpZDtcbiAgICAgICAgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOiByZXBlYXQoYXV0by1maXQsIG1pbm1heCgyNDBweCwgMWZyKSk7XG4gICAgICAgIGdhcDogMC45cmVtO1xuICAgICAgfVxuXG4gICAgICAuZmllbGQge1xuICAgICAgICBkaXNwbGF5OiBncmlkO1xuICAgICAgICBnYXA6IDAuMzVyZW07XG4gICAgICB9XG5cbiAgICAgIC5maWVsZCBzcGFuIHtcbiAgICAgICAgY29sb3I6IHZhcigtLXNhcENvbnRlbnRfTGFiZWxDb2xvcik7XG4gICAgICAgIGZvbnQtc2l6ZTogMC43OHJlbTtcbiAgICAgIH1cblxuICAgICAgLmlubGluZSB7XG4gICAgICAgIGFsaWduLWl0ZW1zOiBlbmQ7XG4gICAgICB9XG5cbiAgICAgIC5hY3Rpb25zIHtcbiAgICAgICAgcGFkZGluZzogMCAxcmVtIDFyZW07XG4gICAgICAgIGRpc3BsYXk6IGZsZXg7XG4gICAgICAgIGdhcDogMC41cmVtO1xuICAgICAgfVxuICAgICJdLCJzb3VyY2VSb290IjoiIn0= */"]
  }));
}
_staticBlock();

/***/ })

}]);
//# sourceMappingURL=apps_moonshot-console_src_app_features_settings_settings_component_ts.js.map