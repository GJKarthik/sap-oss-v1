import { AbstractControl, ValidationErrors, ValidatorFn } from '@angular/forms';

/**
 * Validator that requires the value to contain only Arabic characters, 
 * punctuation, and spaces.
 */
export function arabicScriptValidator(): ValidatorFn {
  return (control: AbstractControl): ValidationErrors | null => {
    if (!control.value) {
      return null;
    }
    
    // Arabic Unicode block: U+0600–U+06FF
    // Arabic Supplement: U+0750–U+077F
    // Arabic Extended-A: U+08A0–U+08FF
    // Arabic Presentation Forms-A: U+FB50–U+FDFF
    // Arabic Presentation Forms-B: U+FE70–U+FEFF
    // Also include common punctuation and digits
    const arabicPattern = /^[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF0-9\s\p{P}]+$/u;
    
    const valid = arabicPattern.test(control.value);
    return valid ? null : { arabicScript: { value: control.value } };
  };
}
