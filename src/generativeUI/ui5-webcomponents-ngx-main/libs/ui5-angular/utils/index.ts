import { fromEvent, map } from "rxjs";

function ProxyInputs(inputNames: string[]) {
  return (cls: any) => {
    inputNames.forEach((inputName) => {
      Object.defineProperty(cls.prototype, inputName, {
        get() {
          return this.element[inputName];
        },
        set(val: any) {
          this.zone.runOutsideAngular(() => (this.element[inputName] = val));
        },
      });
    });
  };
}

function ProxyOutputs(outputNames: string[]) {
  return (cls: any) => {
    outputNames.forEach((outputName) => {
      // eslint-disable-next-line prefer-const
      let [eventName, publicName] = outputName.split(":").map((s) => s.trim());
      publicName = publicName || eventName;
      Object.defineProperty(cls.prototype, publicName, {
        get(): any {
          return fromEvent<CustomEvent<any>>(this.element, eventName).pipe(
            map((e) => e.detail),
          );
        },
      });
    });
  };
}

export { ProxyInputs, ProxyOutputs };
