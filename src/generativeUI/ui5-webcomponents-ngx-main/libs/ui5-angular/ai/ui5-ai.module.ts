import { NgModule } from "@angular/core";
import { Ui5WebcomponentsAiThemingService } from "@ui5/webcomponents-ngx/ai/theming";
import "@ui5/webcomponents-ai/dist/Assets.js";
import { ButtonComponent } from "@ui5/webcomponents-ngx/ai/button";
import { ButtonStateComponent } from "@ui5/webcomponents-ngx/ai/button-state";
import { InputComponent } from "@ui5/webcomponents-ngx/ai/input";
import { PromptInputComponent } from "@ui5/webcomponents-ngx/ai/prompt-input";
import { TextAreaComponent } from "@ui5/webcomponents-ngx/ai/text-area";

const imports = [
  ButtonComponent,
  ButtonStateComponent,
  InputComponent,
  PromptInputComponent,
  TextAreaComponent,
];
const exports = [...imports];

@NgModule({
  imports: [...imports],
  exports: [...exports],
})
class Ui5AiModule {
  constructor(
    ui5WebcomponentsAiThemingService: Ui5WebcomponentsAiThemingService,
  ) {}
}
export { Ui5AiModule };
