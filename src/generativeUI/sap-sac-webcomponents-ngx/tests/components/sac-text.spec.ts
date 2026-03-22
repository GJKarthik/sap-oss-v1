import '@angular/compiler';

import { Injector, runInInjectionContext } from '@angular/core';
import { DomSanitizer } from '@angular/platform-browser';
import { describe, expect, it, vi } from 'vitest';

import {
  SacHeadingComponent,
  SacTextBlockComponent,
  SacDividerComponent,
} from '../../libs/sac-ai-widget/components/sac-text.component';

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
});

describe('SacTextBlockComponent', () => {
  function createTextBlock(): SacTextBlockComponent {
    const sanitizer = {
      bypassSecurityTrustHtml: vi.fn((html: string) => html),
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

  it('converts link markdown', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = '[link](https://example.com)';

    const result = block.sanitizedContent;
    expect(result).toContain('<a href="https://example.com">link</a>');
  });

  it('wraps content in paragraph tags', () => {
    const block = createTextBlock();
    block.markdown = true;
    block.content = 'Hello world';

    const result = String(block.sanitizedContent);
    expect(result).toMatch(/^<p>.*<\/p>$/);
  });
});

describe('SacDividerComponent', () => {
  function createDivider(): SacDividerComponent {
    return new SacDividerComponent();
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
