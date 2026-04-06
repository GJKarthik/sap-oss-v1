declare module '@messageformat/core' {
  export default class MessageFormat {
    constructor(locale: string);
    compile(message: string): (params: Record<string, unknown>) => string;
  }
}
