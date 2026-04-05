import { Pipe, PipeTransform, inject, SecurityContext } from '@angular/core';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { GlossaryService } from '../../services/glossary.service';

/**
 * A pipe that highlights technical glossary terms in text.
 * Wraps found terms in a <mark> tag with a tooltip showing the translation and IFRS context.
 */
@Pipe({
  name: 'glossaryHighlight',
  standalone: true
})
export class GlossaryHighlightPipe implements PipeTransform {
  private readonly glossary = inject(GlossaryService);
  private readonly sanitizer = inject(DomSanitizer);

  transform(value: string | null | undefined): SafeHtml {
    if (!value) return '';

    let highlightedText = value;
    const entries = this.glossary.entries();

    // Sort entries by length (descending) to prevent partial matching of longer terms
    const sortedEntries = [...entries].sort((a, b) => b.en.length - a.en.length);

    for (const entry of sortedEntries) {
      // Highlight English terms
      const enRegex = new RegExp(`\\b${this.escapeRegExp(entry.en)}\\b`, 'gi');
      highlightedText = highlightedText.replace(enRegex, (match) => {
        const tooltip = `AR: ${entry.ar}${entry.ifrs_context ? ' | ' + entry.ifrs_context : ''}`;
        return `<mark class="glossary-term" title="${tooltip}">${match}</mark>`;
      });

      // Highlight Arabic terms
      const arRegex = new RegExp(`${this.escapeRegExp(entry.ar)}`, 'g');
      highlightedText = highlightedText.replace(arRegex, (match) => {
        const tooltip = `EN: ${entry.en}${entry.ifrs_context ? ' | ' + entry.ifrs_context : ''}`;
        return `<mark class="glossary-term" title="${tooltip}">${match}</mark>`;
      });
    }

    return this.sanitizer.bypassSecurityTrustHtml(highlightedText);
  }

  private escapeRegExp(text: string): string {
    return text.replace(/[-[\]{}()*+?.,\\^$|#\s]/g, '\\$&');
  }
}
