# Accessibility Patterns for SAP Generative UI

This document defines the standard accessibility patterns used across all UI channels:
- Data Cleaning Copilot
- SAC Web Components
- UI5 Web Components NGX

## Chat/Message Log Pattern

### Requirements
- Container has `role="log"` and `aria-label="Chat messages"`
- New messages announced via `aria-live="polite"`
- Streaming updates debounced (announce every 1.5s)

### Implementation

```html
<!-- Message Container -->
<div class="chat-messages"
     role="log"
     aria-label="Chat messages"
     aria-live="polite"
     aria-relevant="additions text">
  
  <!-- Individual Message -->
  <article class="message" aria-label="Assistant message">
    <div class="message-content">{{ content }}</div>
  </article>
</div>

<!-- Visually Hidden Announcement Region -->
<div class="sr-only" aria-live="polite" aria-atomic="true">
  {{ streamingAnnouncement }}
</div>
```

### TypeScript

```typescript
private announceStreaming = debounce((content: string) => {
  this.announcement = `Assistant is typing: ${content.slice(-100)}`;
}, 1500);
```

## Focus Management Pattern

### Requirements
- All interactive elements have visible `:focus-visible` styles
- Focus trapped in modals/overlays
- Focus returned to trigger on close

### Implementation

```scss
@use 'src/shared/styles/accessibility' as a11y;

.button {
  @include a11y.focus-visible;
  @include a11y.touch-target(44px);
}

.modal {
  @include a11y.focus-trap-indicator;
}
```

## Color Contrast Pattern

### Requirements
- WCAG AA: 4.5:1 for normal text, 3:1 for large text (18pt+)
- Never rely on color alone (add icons, patterns, or text)

### SAP Fiori Tokens (Pre-validated)

| Combination | Contrast | Status |
|-------------|----------|--------|
| `--sapTextColor` on `--sapBackgroundColor` | 12.6:1 | ✅ |
| `--sapButton_Emphasized_TextColor` on `--sapButton_Emphasized_Background` | 7.2:1 | ✅ |
| `--sapNegativeColor` on `--sapBackgroundColor` | 5.1:1 | ✅ |

### Testing

```typescript
import { testColorContrast } from 'src/shared/testing/accessibility';

const result = testColorContrast('#1d2d3e', '#ffffff');
expect(result.passes).toBe(true);
expect(result.ratio).toBeGreaterThanOrEqual(4.5);
```

## Touch Target Pattern

### Requirements
- Minimum 44×44px for all interactive elements
- Expand click area if visual size must be smaller

### Implementation

```scss
@use 'src/shared/styles/accessibility' as a11y;

// Option 1: Resize element
.icon-button {
  @include a11y.touch-target(44px);
}

// Option 2: Expand click area (visual stays same)
.small-link {
  @include a11y.expand-click-area(8px);
}
```

## Reduced Motion Pattern

### Requirements
- Honor `prefers-reduced-motion: reduce`
- Animations essential to meaning should simplify, not disappear

### Implementation

```scss
@use 'src/shared/styles/accessibility' as a11y;

.streaming-cursor {
  animation: blink 1s step-end infinite;
  
  @include a11y.reduced-motion {
    // Show static cursor instead
    opacity: 1;
  }
}

.slide-in {
  @include a11y.motion-safe(transform, opacity);
}
```

## Screen Reader Announcements

### Status Changes

```typescript
// Connection state
announceToScreenReader(`Connection status: ${state}`);

// Loading
announceToScreenReader('Loading, please wait');

// Completion
announceToScreenReader('Response complete');
```

### Implementation

```typescript
private srAnnouncement = '';

announceToScreenReader(message: string): void {
  this.srAnnouncement = '';
  setTimeout(() => {
    this.srAnnouncement = message;
  }, 50);
}
```

```html
<div class="sr-only" aria-live="polite" aria-atomic="true">
  {{ srAnnouncement }}
</div>
```

## 8px Grid Spacing

### Scale

| Token | Value | Use Case |
|-------|-------|----------|
| `$spacing-xs` | 4px | Tight spaces (icon gaps) |
| `$spacing-sm` | 8px | Default small spacing |
| `$spacing-md` | 16px | Component padding |
| `$spacing-lg` | 24px | Section spacing |
| `$spacing-xl` | 32px | Large gaps |
| `$spacing-xxl` | 48px | Page sections |

### Usage

```scss
@use 'src/shared/styles/accessibility' as a11y;

.message {
  @include a11y.spacing(padding, 'md');  // 16px
  @include a11y.spacing(margin-bottom, 'sm');  // 8px
}
```

## Testing Checklist

### Automated (axe-core)
- [ ] No WCAG AA violations
- [ ] All images have alt text
- [ ] Form inputs have labels

### Manual
- [ ] Keyboard navigation works (Tab, Enter, Escape)
- [ ] Focus indicator visible on all elements
- [ ] Screen reader announces content correctly
- [ ] Content readable at 200% zoom
- [ ] Works with high contrast mode

## Resources

- [WCAG 2.1 Guidelines](https://www.w3.org/WAI/WCAG21/quickref/)
- [SAP Fiori Accessibility](https://experience.sap.com/fiori-design-web/accessibility/)
- [UI5 Web Components A11y](https://sap.github.io/ui5-webcomponents/docs/accessibility/)

