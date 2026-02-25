/**
 * Minimal type declarations for @sap/cds used by cap-llm-plugin.
 * Expand as more modules are migrated to TypeScript.
 */
declare module "@sap/cds" {
  interface CdsDb {
    kind: string;
    run(query: string, params?: unknown[]): Promise<unknown>;
  }

  interface CdsServiceOptions {
    credentials?: {
      schema?: string;
      [key: string]: unknown;
    };
    [key: string]: unknown;
  }

  interface CdsElement {
    name: string;
    "@anonymize"?: string;
    [key: string]: unknown;
  }

  interface CdsEntity {
    name: string;
    projection?: unknown;
    elements: Record<string, CdsElement>;
    "@anonymize"?: string;
    [key: string]: unknown;
  }

  interface CdsService {
    name: string;
    options?: CdsServiceOptions;
    entities: CdsEntity[];
    [key: string]: unknown;
  }

  interface CdsConnectApi {
    to(service: string): Promise<CdsService>;
  }

  interface CdsEnvRequires {
    [key: string]: Record<string, string> | boolean | undefined;
  }

  interface CdsEnv {
    requires: CdsEnvRequires;
    [key: string]: unknown;
  }

  interface Cds {
    db: CdsDb;
    services: CdsService[];
    requires: Record<string, unknown>;
    env: CdsEnv;
    connect: CdsConnectApi;
    once(event: string, handler: (...args: unknown[]) => void): void;
    Service: new () => { init(): Promise<void> };
    [key: string]: unknown;
  }

  const cds: Cds;
  export = cds;
}
