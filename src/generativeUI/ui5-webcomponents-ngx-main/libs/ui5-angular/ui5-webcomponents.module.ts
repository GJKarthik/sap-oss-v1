import { NgModule } from "@angular/core";
import { Ui5FioriModule } from "@ui5/webcomponents-ngx/fiori";
import { Ui5MainModule } from "@ui5/webcomponents-ngx/main";
import { Ui5AiModule } from "@ui5/webcomponents-ngx/ai";

const imports = [Ui5FioriModule, Ui5MainModule, Ui5AiModule];
const exports = [...imports];

@NgModule({
  imports: [...imports],
  exports: [...exports],
})
class Ui5WebcomponentsModule {}
export { Ui5WebcomponentsModule };
