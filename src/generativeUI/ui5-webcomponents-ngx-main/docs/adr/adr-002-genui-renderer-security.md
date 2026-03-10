# ADR-002: GenUI Renderer Security Model (allowlist + DOMPurify)

**Status:** Accepted  
**Date:** 2024-03-01  
**Deciders:** GenUI platform team, Security review  

---

## Context

`genui-renderer` materialises arbitrary A2UI schemas emitted by an AI agent into live DOM. Without constraints, a compromised or hallucinating agent could emit:

- `<script>` tags or `javascript:` hrefs (XSS).
- File-picker, clipboard, or geolocation components that exfiltrate data.
- Deeply nested component trees that cause stack overflows or layout thrashing.
- Components with `innerHTML`-style props containing injected markup.

## Decision

`SchemaValidator` enforces a **three-layer defence**:

1. **Component allowlist** — Only SAP UI5 Web Components (`ui5-*`) and a curated set of layout primitives are permitted. A deny list additionally blocks: `input[type=file]`, `ui5-file-uploader`, `ui5-upload-collection`, `ui5-color-picker`, clipboard APIs, and any component whose tag contains `script`, `iframe`, `object`, `embed`, or `link`.

2. **XSS scan on prop values** — All string prop values are scanned for `<script`, `javascript:`, `on*=`, and `data:text/html` patterns before rendering. Failures produce a `ValidationResult` with `valid: false`; the component is silently dropped, never thrown.

3. **DOMPurify on `innerHTML`-equivalent props** — Any prop named `innerHTML`, `innerText`, or `html` is passed through `DOMPurify.sanitize()` with `FORCE_BODY: true` before assignment.

Schema version mismatches emit a `console.warn` but never block rendering (forward-compatibility principle).

## Consequences

- **Positive:** XSS and data-exfiltration surface area is minimised with no runtime exceptions surfaced to users.
- **Positive:** Allowlist is enforced at validation time, not render time — failures are caught before any DOM mutation.
- **Negative:** New legitimate UI5 components must be explicitly added to the allowlist; agent prompts must be updated accordingly.
- **Negative:** DOMPurify adds ~45 kB (min+gzip) to the bundle. Acceptable given the security benefit.

## Alternatives Considered

- **Angular DomSanitizer only** — insufficient; does not cover Web Component property binding (Shadow DOM bypasses Angular's sanitisation pipeline).
- **CSP header alone** — covers script injection but not component-level data exfiltration.
- **No allowlist, just DOMPurify** — rejected: permits arbitrary custom elements with unknown side-effects.
