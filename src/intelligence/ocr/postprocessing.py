"""OCR post-processing for common misread correction.

Provides configurable text cleanup that fixes frequent Tesseract
misrecognitions — character substitutions, broken ligatures, whitespace
normalisation, and optional dictionary-based correction.
"""

import logging
import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)

# Common Tesseract misreads:  wrong → correct (always applied)
_DEFAULT_CHAR_FIXES: Dict[str, str] = {
    "|": "l",
    "rn": "m",
    "vv": "w",
    "cl": "d",
}

# Context-sensitive fixes: only applied when the character is surrounded
# by letters (not digits/punctuation), preventing "100" → "lOO".
_CONTEXT_CHAR_FIXES: Dict[str, str] = {
    "0": "O",
    "1": "l",
}

# Arabic broken-ligature patterns:  regex → replacement
_ARABIC_LIGATURE_FIXES: List[tuple] = [
    (r"ﻻ", "لا"),
    (r"ﻷ", "لأ"),
    (r"ﻹ", "لإ"),
    (r"ﻵ", "لآ"),
]


@dataclass
class PostprocessingConfig:
    """Configuration for OCR text post-processing.

    Attributes:
        enable_whitespace_norm: Collapse multiple spaces / strip lines.
        enable_char_fixes: Apply common character-substitution fixes.
        custom_char_fixes: Additional caller-supplied substitutions.
        enable_arabic_ligatures: Fix broken Arabic ligature forms.
        enable_dictionary: Use a word list to correct single-char errors.
        dictionary_words: Set of valid words for dictionary correction.
    """

    enable_whitespace_norm: bool = True
    enable_char_fixes: bool = True
    custom_char_fixes: Dict[str, str] = field(default_factory=dict)
    enable_arabic_ligatures: bool = True
    enable_dictionary: bool = False
    dictionary_words: Optional[set] = None


class TextPostprocessor:
    """Applies configurable post-processing rules to OCR text."""

    def __init__(self, config: Optional[PostprocessingConfig] = None):
        self.config = config or PostprocessingConfig()
        # Merge default + custom character fixes
        self._char_fixes: Dict[str, str] = {}
        if self.config.enable_char_fixes:
            self._char_fixes.update(_DEFAULT_CHAR_FIXES)
        self._char_fixes.update(self.config.custom_char_fixes)

    def process(self, text: str) -> str:
        """Run the full post-processing pipeline on *text*.

        Args:
            text: Raw OCR output.

        Returns:
            Cleaned text.
        """
        if not text:
            return text

        # 1. Whitespace normalisation
        if self.config.enable_whitespace_norm:
            text = self._normalise_whitespace(text)

        # 2. Character-substitution fixes
        if self._char_fixes:
            text = self._apply_char_fixes(text)

        # 3. Arabic ligature repair
        if self.config.enable_arabic_ligatures:
            text = self._fix_arabic_ligatures(text)

        # 4. Dictionary correction
        if self.config.enable_dictionary and self.config.dictionary_words:
            text = self._dictionary_correct(text, self.config.dictionary_words)

        return text

    # ------------------------------------------------------------------
    # Steps
    # ------------------------------------------------------------------

    @staticmethod
    def _normalise_whitespace(text: str) -> str:
        """Collapse runs of spaces, strip trailing whitespace per line."""
        lines = text.splitlines()
        cleaned = []
        for line in lines:
            line = re.sub(r"[ \t]+", " ", line).strip()
            cleaned.append(line)
        # Remove excessive blank lines (keep at most one)
        result: List[str] = []
        prev_blank = False
        for line in cleaned:
            if not line:
                if not prev_blank:
                    result.append("")
                prev_blank = True
            else:
                result.append(line)
                prev_blank = False
        return "\n".join(result)

    def _apply_char_fixes(self, text: str) -> str:
        """Apply substring replacements.

        Simple fixes are applied unconditionally.
        Context-sensitive fixes (``0→O``, ``1→l``) are only applied when
        the character is surrounded by letters, preventing ``100→lOO``.
        """
        for wrong, correct in self._char_fixes.items():
            text = text.replace(wrong, correct)
        # Context-sensitive: only replace when surrounded by letters
        for wrong, correct in _CONTEXT_CHAR_FIXES.items():
            result: List[str] = []
            for i, ch in enumerate(text):
                if ch == wrong:
                    before = text[i - 1] if i > 0 else ""
                    after = text[i + 1] if i < len(text) - 1 else ""
                    if before.isalpha() and after.isalpha():
                        result.append(correct)
                    else:
                        result.append(ch)
                else:
                    result.append(ch)
            text = "".join(result)
        return text

    @staticmethod
    def _fix_arabic_ligatures(text: str) -> str:
        """Replace broken Arabic ligature presentation forms."""
        for pattern, replacement in _ARABIC_LIGATURE_FIXES:
            text = re.sub(pattern, replacement, text)
        return text

    @staticmethod
    def _dictionary_correct(text: str, dictionary: set) -> str:
        """Correct single-character errors using a word dictionary.

        For each word not in the dictionary, try replacing each character
        with common alternatives.  Only applies when exactly one substitution
        produces a dictionary hit.
        """
        words = text.split()
        corrected: List[str] = []
        for word in words:
            if word in dictionary or len(word) < 3:
                corrected.append(word)
                continue
            # Try single-char replacements
            candidates: List[str] = []
            for i, ch in enumerate(word):
                for alt in _DEFAULT_CHAR_FIXES.values():
                    candidate = word[:i] + alt + word[i + 1:]
                    if candidate in dictionary:
                        candidates.append(candidate)
            if len(candidates) == 1:
                corrected.append(candidates[0])
            else:
                corrected.append(word)
        return " ".join(corrected)

