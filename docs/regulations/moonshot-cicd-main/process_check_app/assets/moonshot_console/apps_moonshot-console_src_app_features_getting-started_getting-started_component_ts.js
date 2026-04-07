"use strict";
(self["webpackChunkmoonshot_console"] = self["webpackChunkmoonshot_console"] || []).push([["apps_moonshot-console_src_app_features_getting-started_getting-started_component_ts"],{

/***/ 3223:
/*!*********************************************************************************************!*\
  !*** ./apps/moonshot-console/src/app/features/getting-started/getting-started.component.ts ***!
  \*********************************************************************************************/
/***/ ((__unused_webpack_module, __webpack_exports__, __webpack_require__) => {

__webpack_require__.r(__webpack_exports__);
/* harmony export */ __webpack_require__.d(__webpack_exports__, {
/* harmony export */   GettingStartedComponent: () => (/* binding */ GettingStartedComponent)
/* harmony export */ });
/* harmony import */ var _angular_common__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! @angular/common */ 7737);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! @angular/core */ 4131);
/* harmony import */ var _angular_router__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! @angular/router */ 3288);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! @angular/core */ 3499);
var _staticBlock;





function GettingStartedComponent_ui5_li_8_Template(rf, ctx) {
  if (rf & 1) {
    const _r1 = _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵgetCurrentView"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](0, "ui5-li", 9)(1, "ui5-checkbox", 10);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("change", function GettingStartedComponent_ui5_li_8_Template_ui5_checkbox_change_1_listener($event) {
      const item_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵrestoreView"](_r1).$implicit;
      const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵnextContext"]();
      return _angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵresetView"](ctx_r2.setChecked(item_r2.id, ctx_r2.checkedFromEvent($event)));
    });
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](2);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()();
  }
  if (rf & 2) {
    const item_r2 = ctx.$implicit;
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵproperty"]("checked", item_r2.checked);
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate1"](" ", item_r2.label, " ");
  }
}
class GettingStartedComponent {
  constructor() {
    this.router = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_angular_router__WEBPACK_IMPORTED_MODULE_2__.Router);
    this.checklist = [{
      id: 'scope',
      label: 'Assessment scope and system boundaries are defined',
      checked: false
    }, {
      id: 'owners',
      label: 'Business owner, model owner, and risk owner are identified',
      checked: false
    }, {
      id: 'datasets',
      label: 'Data sources and governance constraints are documented',
      checked: false
    }, {
      id: 'runtime',
      label: 'Moonshot runtime endpoint is configured in Settings',
      checked: false
    }];
  }
  setChecked(id, checked) {
    this.checklist = this.checklist.map(item => item.id === id ? {
      ...item,
      checked
    } : item);
  }
  checkedFromEvent(event) {
    const target = event.target;
    return !!target.checked;
  }
  completedCount() {
    return this.checklist.filter(item => item.checked).length;
  }
  go(path) {
    void this.router.navigateByUrl(path);
  }
  static #_ = _staticBlock = () => (this.ɵfac = function GettingStartedComponent_Factory(__ngFactoryType__) {
    return new (__ngFactoryType__ || GettingStartedComponent)();
  }, this.ɵcmp = /*@__PURE__*/_angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdefineComponent"]({
    type: GettingStartedComponent,
    selectors: [["app-getting-started"]],
    decls: 16,
    vars: 4,
    consts: [[1, "page"], ["slot", "header", "title-text", "Getting Started", "subtitle-text", "Prerequisites and setup checks"], ["slot", "avatar", "name", "activate"], [1, "content"], ["class", "check-item", 4, "ngFor", "ngForOf"], [1, "summary"], [1, "actions"], ["design", "Transparent", "icon", "navigation-left-arrow", 3, "click"], ["design", "Emphasized", "icon", "navigation-right-arrow", 3, "click", "disabled"], [1, "check-item"], [3, "change", "checked"]],
    template: function GettingStartedComponent_Template(rf, ctx) {
      if (rf & 1) {
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](0, "section", 0)(1, "ui5-card")(2, "ui5-card-header", 1);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelement"](3, "ui5-icon", 2);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](4, "div", 3)(5, "p");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](6, "Confirm the baseline setup before filling process-check assessments.");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](7, "ui5-list");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtemplate"](8, GettingStartedComponent_ui5_li_8_Template, 3, 2, "ui5-li", 4);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](9, "div", 5);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](10);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](11, "div", 6)(12, "ui5-button", 7);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("click", function GettingStartedComponent_Template_ui5_button_click_12_listener() {
          return ctx.go("/welcome");
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](13, " Back ");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementStart"](14, "ui5-button", 8);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵlistener"]("click", function GettingStartedComponent_Template_ui5_button_click_14_listener() {
          return ctx.go("/process-checks");
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](15, " Continue ");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵelementEnd"]()()()()();
      }
      if (rf & 2) {
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](8);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵproperty"]("ngForOf", ctx.checklist);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](2);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtextInterpolate2"](" Completed ", ctx.completedCount(), " / ", ctx.checklist.length, " prerequisites ");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵadvance"](4);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵproperty"]("disabled", ctx.completedCount() < ctx.checklist.length);
      }
    },
    dependencies: [_angular_common__WEBPACK_IMPORTED_MODULE_0__.CommonModule, _angular_common__WEBPACK_IMPORTED_MODULE_0__.NgForOf],
    styles: [".page[_ngcontent-%COMP%] {\n  display: grid;\n}\n\n.content[_ngcontent-%COMP%] {\n  padding: 1rem;\n  display: grid;\n  gap: 1rem;\n}\n\n.check-item[_ngcontent-%COMP%] {\n  padding: 0.2rem 0;\n}\n\n.summary[_ngcontent-%COMP%] {\n  font-size: 0.82rem;\n  color: var(--sapContent_LabelColor);\n}\n\n.actions[_ngcontent-%COMP%] {\n  display: flex;\n  justify-content: space-between;\n}\n/*# sourceMappingURL=data:application/json;charset=utf-8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIndlYnBhY2s6Ly8uL2FwcHMvbW9vbnNob3QtY29uc29sZS9zcmMvYXBwL2ZlYXR1cmVzL2dldHRpbmctc3RhcnRlZC9nZXR0aW5nLXN0YXJ0ZWQuY29tcG9uZW50LnRzIl0sIm5hbWVzIjpbXSwibWFwcGluZ3MiOiJBQUNNO0VBQ0UsYUFBQTtBQUFSOztBQUdNO0VBQ0UsYUFBQTtFQUNBLGFBQUE7RUFDQSxTQUFBO0FBQVI7O0FBR007RUFDRSxpQkFBQTtBQUFSOztBQUdNO0VBQ0Usa0JBQUE7RUFDQSxtQ0FBQTtBQUFSOztBQUdNO0VBQ0UsYUFBQTtFQUNBLDhCQUFBO0FBQVIiLCJzb3VyY2VzQ29udGVudCI6WyJcbiAgICAgIC5wYWdlIHtcbiAgICAgICAgZGlzcGxheTogZ3JpZDtcbiAgICAgIH1cblxuICAgICAgLmNvbnRlbnQge1xuICAgICAgICBwYWRkaW5nOiAxcmVtO1xuICAgICAgICBkaXNwbGF5OiBncmlkO1xuICAgICAgICBnYXA6IDFyZW07XG4gICAgICB9XG5cbiAgICAgIC5jaGVjay1pdGVtIHtcbiAgICAgICAgcGFkZGluZzogMC4ycmVtIDA7XG4gICAgICB9XG5cbiAgICAgIC5zdW1tYXJ5IHtcbiAgICAgICAgZm9udC1zaXplOiAwLjgycmVtO1xuICAgICAgICBjb2xvcjogdmFyKC0tc2FwQ29udGVudF9MYWJlbENvbG9yKTtcbiAgICAgIH1cblxuICAgICAgLmFjdGlvbnMge1xuICAgICAgICBkaXNwbGF5OiBmbGV4O1xuICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47XG4gICAgICB9XG4gICAgIl0sInNvdXJjZVJvb3QiOiIifQ== */"]
  }));
}
_staticBlock();

/***/ })

}]);
//# sourceMappingURL=apps_moonshot-console_src_app_features_getting-started_getting-started_component_ts.js.map