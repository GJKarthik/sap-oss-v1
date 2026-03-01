// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2023 SAP SE
/**
 * Angular App Bootstrap — OTel + Error Handling Wiring
 *
 * Shows how to register both interceptors (tracing + error handling) and
 * initialise the OpenTelemetry SDK for a standalone Angular 17+ app.
 *
 * Copy this into your `main.ts` (or `app.config.ts`) and adjust as needed.
 *
 * Prerequisites:
 *
 *   npm install \
 *     @opentelemetry/api \
 *     @opentelemetry/sdk-trace-web \
 *     @opentelemetry/exporter-trace-otlp-http \
 *     @opentelemetry/context-zone
 *
 * For NgModule apps see the bottom of this file.
 */

import { bootstrapApplication } from "@angular/platform-browser";
import { provideHttpClient, withInterceptors } from "@angular/common/http";
import { AppComponent } from "./app.component";
import { tracingInterceptorFn } from "./tracing.interceptor";
import { llmErrorInterceptorFn } from "./error.interceptor";

// ════════════════════════════════════════════════════════════════════
// 1. Initialise OpenTelemetry SDK
//    Call this BEFORE bootstrapApplication so the TracerProvider is
//    registered before any HTTP requests are made.
// ════════════════════════════════════════════════════════════════════

function initOpenTelemetry(): void {
  // Dynamic import keeps OTel out of the initial bundle for apps that
  // use lazy loading. Replace with static imports if preferred.
  import("@opentelemetry/sdk-trace-web").then(({ WebTracerProvider }) => {
    import("@opentelemetry/exporter-trace-otlp-http").then(
      ({ OTLPTraceExporter }) => {
        import("@opentelemetry/context-zone").then(({ ZoneContextManager }) => {
          import("@opentelemetry/api").then(({ trace }) => {
            const provider = new WebTracerProvider({
              // Processors and exporters can be added here.
              // Example: export to a local Jaeger / OTEL Collector endpoint.
            });

            provider.addSpanProcessor(
              // SimpleSpanProcessor for development; use BatchSpanProcessor in prod.
              new (require("@opentelemetry/sdk-trace-base").SimpleSpanProcessor)(
                new OTLPTraceExporter({
                  url: "http://localhost:4318/v1/traces",
                }),
              ),
            );

            provider.register({
              // ZoneContextManager propagates context through Angular's Zone.js
              contextManager: new ZoneContextManager(),
            });

            console.debug("[OTel] TracerProvider registered.");
          });
        });
      },
    );
  });
}

// ════════════════════════════════════════════════════════════════════
// 2. Bootstrap the Angular app with both interceptors
// ════════════════════════════════════════════════════════════════════

initOpenTelemetry();

bootstrapApplication(AppComponent, {
  providers: [
    provideHttpClient(
      withInterceptors([
        // Order matters: tracing runs first (outermost), so the span is
        // active when the error interceptor executes.
        tracingInterceptorFn,
        llmErrorInterceptorFn,
      ]),
    ),
  ],
}).catch((err: unknown) => console.error(err));

// ════════════════════════════════════════════════════════════════════
// NgModule equivalent (copy into app.module.ts providers array)
// ════════════════════════════════════════════════════════════════════
//
// import { HTTP_INTERCEPTORS } from "@angular/common/http";
// import { TracingInterceptor } from "./tracing.interceptor";
// import { LLMErrorInterceptor } from "./error.interceptor";
//
// @NgModule({
//   providers: [
//     // Tracing must be listed first so its span is active when the
//     // error interceptor's catchError handler runs.
//     { provide: HTTP_INTERCEPTORS, useClass: TracingInterceptor, multi: true },
//     { provide: HTTP_INTERCEPTORS, useClass: LLMErrorInterceptor, multi: true },
//   ],
// })
// export class AppModule {}
