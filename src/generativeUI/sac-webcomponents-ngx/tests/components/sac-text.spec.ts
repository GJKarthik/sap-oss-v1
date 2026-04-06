import '@angular/compiler';

import { Injector, SecurityContext, runInInjectionContext } from '@angular/core';
import { DomSanitizer } from '@angular/platform-browser';
import { describe, expect, it, vi } from 'vitest';

import {
  SacHeadingComponent,
  SacTextBlockComponent,
  SacDividerComponent,
} from '../../libs/sac-ai-widget/components/sac-text.component';
import { SacI18nService } from '../../libs/sac-core/src/lib/services/sac-i18n.service';

describe('SacHeadingComponent', () => {
  function createHeading(): SacHeadingComponent {
    return new SacHeadingComponent();
  }

  it('computes heading class from level', () => {
    const heading = createHeading();
    heading.level = 3;
    expect(heading.headingClass).toBe('sac-heading sac-heading--3');
  });

  it('defaults to level 2', () => {
    const heading = createHeading();
    expect(heading.level).toBe(2);
    expect(heading.headingClass).toBe('sac-heading sac-heading--2');
  });

  it('supports all heading levels 1-6', () => {
    const heading = createHeading();
    for (const level of [1, 2, 3, 4, 5, 6] as const) {
      heading.level = level;
      expect(heading.headingClass).toBe(`sac-heading sac-heading--${level}`);
    }
  });

  it('defaults content to empty string', () => {
    const heading = createHeading();
    expect(heading.content).toBe('');
  });

  it('defaults alignment to left', () => {
    const heading = createHeading();
    expect(heading.align).toBe('left');
  });

  it('computes estimated heading height for runtime layout stability', () => {
    const heading = createHeading();
    heading.content = 'Quarterly Performance Overview';
    heading.level = 2;

    expect(heading.estimatedMinHeightPx).toBeGreaterThan(0);
  });
});

describe('SacTextBlockComponent', () => {
  function createTextBlock(): SacTextBlockComponent {
    // Use a sanitizer that mimics Angular's real sanitize() behavior:
    // strips dangerous tags/attributes but keeps safe HTML
    const sanitizer = {
      sanitize: vi.fn((_ctx: SecurityContext, html: string) => {
        // Simulate Angular's sanitizer: strip script, onerror, javascript: etc.
        return html
          .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '')
          .replace(/<\/?script[^>]*>/gi, '')
          .replace(/\s*on\w+\s*=\s*["'][^"']*["']/gi, '')
          .replace(/href\s*=\s*["']javascript:[^"']*["']/gi, 'href=""')
          .replace(/<iframe\b[^>]*>[\s\S]*?<\/iframe>/gi, '')
          .replace(/<object\b[^>]*>[\s\S]*?<\/object>/gi, '');
      }),
    } as unknown as DomSanitizer;

    const injector = Injector.create({
      providers: [
        { provide: DomSanitizer, useValue: sanitizer },
      ],
    });

    return runInInjectionContext(injector, () => new SacTextBlockComponent(sanitizer));
  }

  it('defaults markdown to false', () => {
    const block = createTextBlock();
    expect(block.markdown).toBe(false);
  });

  it('defaults alignment to left', () => {
    const block = createTextBlock();
    expect(block.align).toBe('left');
  });

  it('returns sanitized content for markdown mode', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = '**bold** text';

    const result = block.sanitizedContent;
    expect(result).toContain('<strong>bold</strong>');
  });

  it('converts italic markdown', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = '*italic* text';

    const result = block.sanitizedContent;
    expect(result).toContain('<em>italic</em>');
  });

  it('converts link markdown with https', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = '[link](https://example.com)';

    const result = block.sanitizedContent;
    expect(result).toContain('href="https://example.com"');
  });

  it('wraps content in paragraph tags', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = 'Hello world';

    const result = String(block.sanitizedContent);
    expect(result).toMatch(/^<p>.*<\/p>$/);
  });

  // =========================================================================
  // XSS Security Tests
  // =========================================================================

  it('blocks <script> tags in content', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = 'Hello <script>alert(1)</script> world';

    const result = String(block.sanitizedContent);
    expect(result).not.toContain('<script>');
    expect(result).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
  });

  it('blocks javascript: URI in markdown links', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = '[click me](javascript:alert(document.cookie))';

    const result = String(block.sanitizedContent);
    // The link regex only allows https?:// so javascript: should not produce an href
    expect(result).toContain('javascript:');
    // The text should still appear but not as a link
    expect(result).not.toMatch(/href="javascript:/);
    expect(result).not.toContain('<a ');
  });

  it('blocks data: URI in markdown links', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = '[payload](data:text/html,<script>alert(1)</script>)';

    const result = String(block.sanitizedContent);
    expect(result).not.toContain('href="data:');
  });

  it('escapes raw HTML tags injected in content', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = '<img onerror=alert(1) src=x>';

    const result = String(block.sanitizedContent);
    // Raw < should be escaped to &lt; before markdown transforms
    expect(result).not.toContain('<img');
    expect(result).toContain('onerror=alert(1)');
    expect(result).toContain('&lt;img');
  });

  it('escapes HTML entities to prevent injection', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = '"><svg onload=alert(1)>';

    const result = String(block.sanitizedContent);
    expect(result).not.toContain('<svg');
    expect(result).toContain('onload=alert(1)');
    expect(result).toContain('&quot;');
    expect(result).toContain('&lt;svg');
  });

  it('blocks iframe injection in content', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = '<iframe src="https://evil.com"></iframe>';

    const result = String(block.sanitizedContent);
    expect(result).not.toContain('<iframe');
  });

  it('allows safe markdown while blocking injection in same content', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = '**Important:** Do not click <script>alert("xss")</script> this [safe link](https://sap.com)';

    const result = String(block.sanitizedContent);
    expect(result).toContain('<strong>Important:</strong>');
    expect(result).toContain('href="https://sap.com"');
    expect(result).not.toContain('<script>');
    expect(result).not.toContain('alert("xss")');
  });

  it('computes estimated text block height for runtime layout stability', () => {
    const block = createTextBlock();
    block.content = 'Revenue increased 12% year-over-year across all regions.';

    expect(block.estimatedMinHeightPx).toBeGreaterThan(0);
  });
});

describe('SacDividerComponent', () => {
  function createDivider(): SacDividerComponent {
    const injector = Injector.create({
      providers: [
        { provide: SacI18nService, useClass: SacI18nService },
      ],
    });
    return runInInjectionContext(injector, () => new SacDividerComponent());
  }

  it('defaults variant to default', () => {
    const divider = createDivider();
    expect(divider.variant).toBe('default');
  });

  it('defaults spacing to 2 (16px)', () => {
    const divider = createDivider();
    expect(divider.spacing).toBe(2);
  });

  it('defaults ariaLabel to Content separator', () => {
    const divider = createDivider();
    expect(divider.ariaLabel).toBe('Content separator');
  });
});
