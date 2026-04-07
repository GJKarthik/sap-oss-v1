"use strict";
(self["webpackChunkmoonshot_console"] = self["webpackChunkmoonshot_console"] || []).push([["apps_moonshot-console_src_app_features_catalog_catalog_component_ts"],{

/***/ 3963:
/*!*****************************************************************************!*\
  !*** ./apps/moonshot-console/src/app/features/catalog/catalog.component.ts ***!
  \*****************************************************************************/
/***/ ((__unused_webpack_module, __webpack_exports__, __webpack_require__) => {

__webpack_require__.r(__webpack_exports__);
/* harmony export */ __webpack_require__.d(__webpack_exports__, {
/* harmony export */   CatalogComponent: () => (/* binding */ CatalogComponent)
/* harmony export */ });
/* harmony import */ var _angular_common__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! @angular/common */ 7737);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! @angular/core */ 4131);
/* harmony import */ var _angular_core_rxjs_interop__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! @angular/core/rxjs-interop */ 5768);
/* harmony import */ var _core_services_moonshot_api_service__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! ../../core/services/moonshot-api.service */ 5509);
/* harmony import */ var _angular_core__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__(/*! @angular/core */ 3499);
var _staticBlock;






function CatalogComponent_ui5_list_13_ui5_li_1_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "ui5-li", 19);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](1);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const connector_r2 = ctx.$implicit;
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](connector_r2);
  }
}
function CatalogComponent_ui5_list_13_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "ui5-list");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](1, CatalogComponent_ui5_list_13_ui5_li_1_Template, 2, 1, "ui5-li", 18);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵnextContext"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngForOf", ctx_r2.summary == null ? null : ctx_r2.summary.connectors);
  }
}
function CatalogComponent_ui5_list_17_ui5_li_1_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "ui5-li", 21);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](1);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const metric_r4 = ctx.$implicit;
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](metric_r4);
  }
}
function CatalogComponent_ui5_list_17_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "ui5-list");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](1, CatalogComponent_ui5_list_17_ui5_li_1_Template, 2, 1, "ui5-li", 20);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵnextContext"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngForOf", ctx_r2.summary == null ? null : ctx_r2.summary.metrics);
  }
}
function CatalogComponent_ui5_list_21_ui5_li_1_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "ui5-li", 23);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](1);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const module_r5 = ctx.$implicit;
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](module_r5);
  }
}
function CatalogComponent_ui5_list_21_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "ui5-list");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](1, CatalogComponent_ui5_list_21_ui5_li_1_Template, 2, 1, "ui5-li", 22);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
  if (rf & 2) {
    const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵnextContext"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngForOf", ctx_r2.summary == null ? null : ctx_r2.summary.attack_modules);
  }
}
function CatalogComponent_ui5_table_row_32_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "ui5-table-row")(1, "ui5-table-cell");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](2);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](3, "ui5-table-cell");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](4);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
  }
  if (rf & 2) {
    const testId_r6 = ctx.$implicit;
    const ctx_r2 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵnextContext"]();
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](2);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](testId_r6);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](2);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtextInterpolate"](ctx_r2.describeTestConfig(testId_r6));
  }
}
function CatalogComponent_p_33_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "p", 24);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](1, "No test config IDs found.");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
}
function CatalogComponent_ng_template_34_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "p", 24);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](1, "No connectors available.");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
}
function CatalogComponent_ng_template_36_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "p", 24);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](1, "No metrics available.");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
}
function CatalogComponent_ng_template_38_Template(rf, ctx) {
  if (rf & 1) {
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "p", 24);
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](1, "No attack modules available.");
    _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
  }
}
class CatalogComponent {
  constructor() {
    this.destroyRef = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_angular_core__WEBPACK_IMPORTED_MODULE_1__.DestroyRef);
    this.moonshot = (0,_angular_core__WEBPACK_IMPORTED_MODULE_1__.inject)(_core_services_moonshot_api_service__WEBPACK_IMPORTED_MODULE_3__.MoonshotApiService);
    this.summary = null;
    this.tests = null;
    this.testConfigIds = [];
    this.refresh();
  }
  refresh() {
    this.moonshot.getConfigSummary().pipe((0,_angular_core_rxjs_interop__WEBPACK_IMPORTED_MODULE_2__.takeUntilDestroyed)(this.destroyRef)).subscribe(summary => {
      this.summary = summary;
    });
    this.moonshot.getTestConfigs().pipe((0,_angular_core_rxjs_interop__WEBPACK_IMPORTED_MODULE_2__.takeUntilDestroyed)(this.destroyRef)).subscribe(tests => {
      this.tests = tests;
      this.testConfigIds = tests.test_config_ids ?? [];
    });
  }
  describeTestConfig(testId) {
    if (!this.tests) {
      return 'unknown';
    }
    const entry = this.tests.test_configs[testId];
    if (Array.isArray(entry)) {
      return `${entry.length} test entry(s)`;
    }
    if (entry && typeof entry === 'object') {
      return 'single test object';
    }
    return typeof entry;
  }
  static #_ = _staticBlock = () => (this.ɵfac = function CatalogComponent_Factory(__ngFactoryType__) {
    return new (__ngFactoryType__ || CatalogComponent)();
  }, this.ɵcmp = /*@__PURE__*/_angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵdefineComponent"]({
    type: CatalogComponent,
    selectors: [["app-catalog"]],
    decls: 40,
    vars: 8,
    consts: [["noConnectors", ""], ["noMetrics", ""], ["noModules", ""], [1, "page"], [1, "header-row"], ["level", "H2"], [1, "subtitle"], ["icon", "refresh", "design", "Transparent", 3, "click"], [1, "grid"], ["slot", "header", "title-text", "Connectors"], [1, "card-content"], [4, "ngIf", "ngIfElse"], ["slot", "header", "title-text", "Metrics"], ["slot", "header", "title-text", "Attack Modules"], ["slot", "header", "title-text", "Test Config IDs", "subtitle-text", "From /api/moonshot/test-configs"], ["slot", "columns"], [4, "ngFor", "ngForOf"], ["class", "empty", 4, "ngIf"], ["icon", "machine", 4, "ngFor", "ngForOf"], ["icon", "machine"], ["icon", "accept", 4, "ngFor", "ngForOf"], ["icon", "accept"], ["icon", "warning", 4, "ngFor", "ngForOf"], ["icon", "warning"], [1, "empty"]],
    template: function CatalogComponent_Template(rf, ctx) {
      if (rf & 1) {
        const _r1 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵgetCurrentView"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](0, "section", 3)(1, "div", 4)(2, "div")(3, "ui5-title", 5);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](4, "Available Tests + Connectors");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](5, "p", 6);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](6, "Backed by Moonshot config and test-config exports.");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](7, "ui5-button", 7);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵlistener"]("click", function CatalogComponent_Template_ui5_button_click_7_listener() {
          _angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵrestoreView"](_r1);
          return _angular_core__WEBPACK_IMPORTED_MODULE_1__["ɵɵresetView"](ctx.refresh());
        });
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](8, "Reload");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](9, "div", 8)(10, "ui5-card");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelement"](11, "ui5-card-header", 9);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](12, "div", 10);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](13, CatalogComponent_ui5_list_13_Template, 2, 1, "ui5-list", 11);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](14, "ui5-card");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelement"](15, "ui5-card-header", 12);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](16, "div", 10);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](17, CatalogComponent_ui5_list_17_Template, 2, 1, "ui5-list", 11);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](18, "ui5-card");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelement"](19, "ui5-card-header", 13);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](20, "div", 10);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](21, CatalogComponent_ui5_list_21_Template, 2, 1, "ui5-list", 11);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](22, "ui5-card");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelement"](23, "ui5-card-header", 14);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](24, "div", 10)(25, "ui5-table")(26, "ui5-table-column", 15)(27, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](28, "Test Config ID");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementStart"](29, "ui5-table-column", 15)(30, "span");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtext"](31, "Definition Type");
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](32, CatalogComponent_ui5_table_row_32_Template, 5, 2, "ui5-table-row", 16);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](33, CatalogComponent_p_33_Template, 2, 0, "p", 17);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]()();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplate"](34, CatalogComponent_ng_template_34_Template, 2, 0, "ng-template", null, 0, _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplateRefExtractor"])(36, CatalogComponent_ng_template_36_Template, 2, 0, "ng-template", null, 1, _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplateRefExtractor"])(38, CatalogComponent_ng_template_38_Template, 2, 0, "ng-template", null, 2, _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵtemplateRefExtractor"]);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵelementEnd"]();
      }
      if (rf & 2) {
        const noConnectors_r7 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵreference"](35);
        const noMetrics_r8 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵreference"](37);
        const noModules_r9 = _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵreference"](39);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](13);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngIf", ctx.summary == null ? null : ctx.summary.connectors == null ? null : ctx.summary.connectors.length)("ngIfElse", noConnectors_r7);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](4);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngIf", ctx.summary == null ? null : ctx.summary.metrics == null ? null : ctx.summary.metrics.length)("ngIfElse", noMetrics_r8);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](4);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngIf", ctx.summary == null ? null : ctx.summary.attack_modules == null ? null : ctx.summary.attack_modules.length)("ngIfElse", noModules_r9);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"](11);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngForOf", ctx.testConfigIds);
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵadvance"]();
        _angular_core__WEBPACK_IMPORTED_MODULE_4__["ɵɵproperty"]("ngIf", ctx.testConfigIds.length === 0);
      }
    },
    dependencies: [_angular_common__WEBPACK_IMPORTED_MODULE_0__.CommonModule, _angular_common__WEBPACK_IMPORTED_MODULE_0__.NgForOf, _angular_common__WEBPACK_IMPORTED_MODULE_0__.NgIf],
    styles: [".page[_ngcontent-%COMP%] {\n  display: grid;\n  gap: 1rem;\n}\n\n.header-row[_ngcontent-%COMP%] {\n  display: flex;\n  justify-content: space-between;\n  gap: 1rem;\n  align-items: center;\n}\n\n.subtitle[_ngcontent-%COMP%] {\n  margin: 0.4rem 0 0;\n  color: var(--sapContent_LabelColor);\n}\n\n.grid[_ngcontent-%COMP%] {\n  display: grid;\n  grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));\n  gap: 1rem;\n}\n\n.card-content[_ngcontent-%COMP%] {\n  padding: 0.9rem;\n}\n\n.empty[_ngcontent-%COMP%] {\n  font-style: italic;\n  color: var(--sapContent_LabelColor);\n}\n\n@media (max-width: 760px) {\n  .header-row[_ngcontent-%COMP%] {\n    align-items: flex-start;\n    flex-direction: column;\n  }\n}\n/*# sourceMappingURL=data:application/json;charset=utf-8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIndlYnBhY2s6Ly8uL2FwcHMvbW9vbnNob3QtY29uc29sZS9zcmMvYXBwL2ZlYXR1cmVzL2NhdGFsb2cvY2F0YWxvZy5jb21wb25lbnQudHMiXSwibmFtZXMiOltdLCJtYXBwaW5ncyI6IkFBQ007RUFDRSxhQUFBO0VBQ0EsU0FBQTtBQUFSOztBQUdNO0VBQ0UsYUFBQTtFQUNBLDhCQUFBO0VBQ0EsU0FBQTtFQUNBLG1CQUFBO0FBQVI7O0FBR007RUFDRSxrQkFBQTtFQUNBLG1DQUFBO0FBQVI7O0FBR007RUFDRSxhQUFBO0VBQ0EsMkRBQUE7RUFDQSxTQUFBO0FBQVI7O0FBR007RUFDRSxlQUFBO0FBQVI7O0FBR007RUFDRSxrQkFBQTtFQUNBLG1DQUFBO0FBQVI7O0FBR007RUFDRTtJQUNFLHVCQUFBO0lBQ0Esc0JBQUE7RUFBUjtBQUNGIiwic291cmNlc0NvbnRlbnQiOlsiXG4gICAgICAucGFnZSB7XG4gICAgICAgIGRpc3BsYXk6IGdyaWQ7XG4gICAgICAgIGdhcDogMXJlbTtcbiAgICAgIH1cblxuICAgICAgLmhlYWRlci1yb3cge1xuICAgICAgICBkaXNwbGF5OiBmbGV4O1xuICAgICAgICBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47XG4gICAgICAgIGdhcDogMXJlbTtcbiAgICAgICAgYWxpZ24taXRlbXM6IGNlbnRlcjtcbiAgICAgIH1cblxuICAgICAgLnN1YnRpdGxlIHtcbiAgICAgICAgbWFyZ2luOiAwLjRyZW0gMCAwO1xuICAgICAgICBjb2xvcjogdmFyKC0tc2FwQ29udGVudF9MYWJlbENvbG9yKTtcbiAgICAgIH1cblxuICAgICAgLmdyaWQge1xuICAgICAgICBkaXNwbGF5OiBncmlkO1xuICAgICAgICBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHJlcGVhdChhdXRvLWZpdCwgbWlubWF4KDI2MHB4LCAxZnIpKTtcbiAgICAgICAgZ2FwOiAxcmVtO1xuICAgICAgfVxuXG4gICAgICAuY2FyZC1jb250ZW50IHtcbiAgICAgICAgcGFkZGluZzogMC45cmVtO1xuICAgICAgfVxuXG4gICAgICAuZW1wdHkge1xuICAgICAgICBmb250LXN0eWxlOiBpdGFsaWM7XG4gICAgICAgIGNvbG9yOiB2YXIoLS1zYXBDb250ZW50X0xhYmVsQ29sb3IpO1xuICAgICAgfVxuXG4gICAgICBAbWVkaWEgKG1heC13aWR0aDogNzYwcHgpIHtcbiAgICAgICAgLmhlYWRlci1yb3cge1xuICAgICAgICAgIGFsaWduLWl0ZW1zOiBmbGV4LXN0YXJ0O1xuICAgICAgICAgIGZsZXgtZGlyZWN0aW9uOiBjb2x1bW47XG4gICAgICAgIH1cbiAgICAgIH1cbiAgICAiXSwic291cmNlUm9vdCI6IiJ9 */"]
  }));
}
_staticBlock();

/***/ })

}]);
//# sourceMappingURL=apps_moonshot-console_src_app_features_catalog_catalog_component_ts.js.map