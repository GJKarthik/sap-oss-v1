/**
 * Date Format Pipe
 * 
 * A consistent date formatting pipe using Intl.DateTimeFormat
 * for locale-aware, consistent date display across the application.
 */

import { Pipe, PipeTransform } from '@angular/core';

export type DateFormatStyle = 'short' | 'medium' | 'long' | 'full' | 'relative' | 'datetime' | 'date' | 'time';

@Pipe({
  name: 'appDateFormat',
  standalone: true
})
export class DateFormatPipe implements PipeTransform {
  private static readonly locale = 'en-US';
  
  private static readonly formatters: Record<string, Intl.DateTimeFormat> = {
    short: new Intl.DateTimeFormat(DateFormatPipe.locale, {
      year: 'numeric',
      month: 'numeric',
      day: 'numeric'
    }),
    medium: new Intl.DateTimeFormat(DateFormatPipe.locale, {
      year: 'numeric',
      month: 'short',
      day: 'numeric'
    }),
    long: new Intl.DateTimeFormat(DateFormatPipe.locale, {
      year: 'numeric',
      month: 'long',
      day: 'numeric'
    }),
    full: new Intl.DateTimeFormat(DateFormatPipe.locale, {
      weekday: 'long',
      year: 'numeric',
      month: 'long',
      day: 'numeric'
    }),
    datetime: new Intl.DateTimeFormat(DateFormatPipe.locale, {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
      hour12: true
    }),
    date: new Intl.DateTimeFormat(DateFormatPipe.locale, {
      year: 'numeric',
      month: 'short',
      day: 'numeric'
    }),
    time: new Intl.DateTimeFormat(DateFormatPipe.locale, {
      hour: 'numeric',
      minute: '2-digit',
      second: '2-digit',
      hour12: true
    })
  };

  transform(value: string | number | Date | null | undefined, style: DateFormatStyle = 'datetime'): string {
    if (!value) {
      return 'n/a';
    }

    const date = value instanceof Date ? value : new Date(value);
    
    if (Number.isNaN(date.getTime())) {
      return typeof value === 'string' ? value : 'Invalid date';
    }

    if (style === 'relative') {
      return this.getRelativeTime(date);
    }

    const formatter = DateFormatPipe.formatters[style] || DateFormatPipe.formatters['datetime'];
    return formatter.format(date);
  }

  private getRelativeTime(date: Date): string {
    const now = new Date();
    const diffMs = now.getTime() - date.getTime();
    const diffSeconds = Math.floor(diffMs / 1000);
    const diffMinutes = Math.floor(diffSeconds / 60);
    const diffHours = Math.floor(diffMinutes / 60);
    const diffDays = Math.floor(diffHours / 24);
    const diffWeeks = Math.floor(diffDays / 7);
    const diffMonths = Math.floor(diffDays / 30);
    const diffYears = Math.floor(diffDays / 365);

    // Future dates
    if (diffMs < 0) {
      return DateFormatPipe.formatters['datetime'].format(date);
    }

    if (diffSeconds < 60) {
      return 'Just now';
    }

    if (diffMinutes < 60) {
      return diffMinutes === 1 ? '1 minute ago' : `${diffMinutes} minutes ago`;
    }

    if (diffHours < 24) {
      return diffHours === 1 ? '1 hour ago' : `${diffHours} hours ago`;
    }

    if (diffDays < 7) {
      return diffDays === 1 ? 'Yesterday' : `${diffDays} days ago`;
    }

    if (diffWeeks < 4) {
      return diffWeeks === 1 ? '1 week ago' : `${diffWeeks} weeks ago`;
    }

    if (diffMonths < 12) {
      return diffMonths === 1 ? '1 month ago' : `${diffMonths} months ago`;
    }

    return diffYears === 1 ? '1 year ago' : `${diffYears} years ago`;
  }
}