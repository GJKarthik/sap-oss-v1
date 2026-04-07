"use strict";
(self["webpackChunkmoonshot_console"] = self["webpackChunkmoonshot_console"] || []).push([["apps_moonshot-console_src_app_features_welcome_welcome_component_ts"],{

/***/ 5907:
/*!*****************************************************************************!*\
  !*** ./apps/moonshot-console/src/app/features/welcome/welcome.component.ts ***!
  \*****************************************************************************/
/***/ ((__unused_webpack_module, __webpack_exports__, __webpack_require__) => {

__webpack_require__.r(__webpack_exports__);
/* harmony export */ __webpack_require__.d(__webpack_exports__, {
/* harmony export */   WelcomeComponent: () => (/* binding */ WelcomeComponent)
/* harmony export */ });
/* harmony import */ var _angular_common__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! @angular/common */ 7737);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! @angular/core */ 4131);
/* harmony import */ var _angular_router__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! @angular/router */ 3288);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! @angular/core */ 3499);
var _staticBlock;




class WelcomeComponent {
  constructor() {
    this.router = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_angular_router__WEBPACK_IMPORTED_MODULE_2__.Router);
  }
  go(path) {
    void this.router.navigateByUrl(path);
  }
  static #_ = _staticBlock = () => (this.ɵfac = function WelcomeComponent_Factory(__ngFactoryType__) {
    return new (__ngFactoryType__ || WelcomeComponent)();
  }, this.ɵcmp = /*@__PURE__*/_angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdefineComponent"]({
    type: WelcomeComponent,
    selectors: [["app-welcome"]],
    decls: 33,
    vars: 0,
    consts: [[1, "page"], ["slot", "header", "title-text", "AI Verify Process Checks", "subtitle-text", "Replaced Streamlit runtime with Angular + UI5"], ["slot", "avatar", "name", "official-service"], [1, "content"], [1, "steps"], [1, "step"], [1, "actions"], ["design", "Emphasized", "icon", "navigation-right-arrow", 3, "click"], ["design", "Transparent", "icon", "machine", 3, "click"]],
    template: function WelcomeComponent_Template(rf, ctx) {
      if (rf & 1) {
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](0, "section", 0)(1, "ui5-card")(2, "ui5-card-header", 1);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElement"](3, "ui5-icon", 2);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](4, "div", 3)(5, "p");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](6, " This is the integrated Moonshot Process Check application. Complete governance checks, upload Moonshot run results, and generate report artifacts from one UI. ");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](7, "div", 4)(8, "div", 5)(9, "strong");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](10, "1.");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](11, " Getting Started");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](12, "div", 5)(13, "strong");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](14, "2.");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](15, " Process Checks");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](16, "div", 5)(17, "strong");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](18, "3.");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](19, " Upload Technical Results");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](20, "div", 5)(21, "strong");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](22, "4.");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](23, " Generate Report");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](24, "div", 5)(25, "strong");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](26, "5.");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](27, " Moonshot Runtime Console");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](28, "div", 6)(29, "ui5-button", 7);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomListener"]("click", function WelcomeComponent_Template_ui5_button_click_29_listener() {
          return ctx.go("/getting-started");
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](30, " Start Assessment ");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementStart"](31, "ui5-button", 8);
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomListener"]("click", function WelcomeComponent_Template_ui5_button_click_31_listener() {
          return ctx.go("/overview");
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵtext"](32, " Open Runtime Overview ");
        _angular_core__WEBPACK_IMPORTED_MODULE_3__["ɵɵdomElementEnd"]()()()()();
      }
    },
    dependencies: [_angular_common__WEBPACK_IMPORTED_MODULE_0__.CommonModule],
    styles: [".page[_ngcontent-%COMP%] {\n  display: grid;\n}\n\n.content[_ngcontent-%COMP%] {\n  padding: 1rem;\n  display: grid;\n  gap: 1rem;\n}\n\n.steps[_ngcontent-%COMP%] {\n  display: grid;\n  gap: 0.5rem;\n}\n\n.step[_ngcontent-%COMP%] {\n  padding: 0.55rem 0.7rem;\n  border: 1px solid var(--moonshot-border);\n  border-radius: 8px;\n  background: var(--moonshot-panel);\n}\n\n.actions[_ngcontent-%COMP%] {\n  display: flex;\n  gap: 0.6rem;\n  flex-wrap: wrap;\n}\n/*# sourceMappingURL=data:application/json;charset=utf-8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIndlYnBhY2s6Ly8uL2FwcHMvbW9vbnNob3QtY29uc29sZS9zcmMvYXBwL2ZlYXR1cmVzL3dlbGNvbWUvd2VsY29tZS5jb21wb25lbnQudHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IkFBQ007RUFDRSxhQUFBO0FBQVI7O0FBR007RUFDRSxhQUFBO0VBQ0EsYUFBQTtFQUNBLFNBQUE7QUFBUjs7QUFHTTtFQUNFLGFBQUE7RUFDQSxXQUFBO0FBQVI7O0FBR007RUFDRSx1QkFBQTtFQUNBLHdDQUFBO0VBQ0Esa0JBQUE7RUFDQSxpQ0FBQTtBQUFSOztBQUdNO0VBQ0UsYUFBQTtFQUNBLFdBQUE7RUFDQSxlQUFBO0FBQVIiLCJzb3VyY2VzQ29udGVudCI6WyJcbiAgICAgIC5wYWdlIHtcbiAgICAgICAgZGlzcGxheTogZ3JpZDtcbiAgICAgIH1cblxuICAgICAgLmNvbnRlbnQge1xuICAgICAgICBwYWRkaW5nOiAxcmVtO1xuICAgICAgICBkaXNwbGF5OiBncmlkO1xuICAgICAgICBnYXA6IDFyZW07XG4gICAgICB9XG5cbiAgICAgIC5zdGVwcyB7XG4gICAgICAgIGRpc3BsYXk6IGdyaWQ7XG4gICAgICAgIGdhcDogMC41cmVtO1xuICAgICAgfVxuXG4gICAgICAuc3RlcCB7XG4gICAgICAgIHBhZGRpbmc6IDAuNTVyZW0gMC43cmVtO1xuICAgICAgICBib3JkZXI6IDFweCBzb2xpZCB2YXIoLS1tb29uc2hvdC1ib3JkZXIpO1xuICAgICAgICBib3JkZXItcmFkaXVzOiA4cHg7XG4gICAgICAgIGJhY2tncm91bmQ6IHZhcigtLW1vb25zaG90LXBhbmVsKTtcbiAgICAgIH1cblxuICAgICAgLmFjdGlvbnMge1xuICAgICAgICBkaXNwbGF5OiBmbGV4O1xuICAgICAgICBnYXA6IDAuNnJlbTtcbiAgICAgICAgZmxleC13cmFwOiB3cmFwO1xuICAgICAgfVxuICAgICJdLCJzb3VyY2VSb290IjoiIn0= */"]
  }));
}
_staticBlock();

/***/ })

}]);
//# sourceMappingURL=apps_moonshot-console_src_app_features_welcome_welcome_component_ts.js.map