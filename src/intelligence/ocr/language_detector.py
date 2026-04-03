"""Automatic script/language detection for OCR pages.

Analyses character distributions in a low-confidence OCR pass to determine
the dominant script(s) on a page, then returns the optimal Tesseract
language string.
"""

import logging
import re
from typing import Dict, Optional

logger = logging.getLogger(__name__)

# Unicode block ranges for common scripts
_SCRIPT_PATTERNS: Dict[str, re.Pattern] = {
    "ara": re.compile(r"[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]"),
    "eng": re.compile(r"[a-zA-Z]"),
    "deu": re.compile(r"[äöüßÄÖÜ]"),
    "fra": re.compile(r"[àâæçéèêëïîôœùûüÿÀÂÆÇÉÈÊËÏÎÔŒÙÛÜŸ]"),
    "spa": re.compile(r"[áéíóúñüÁÉÍÓÚÑÜ¿¡]"),
    "hin": re.compile(r"[\u0900-\u097F]"),
    "zho": re.compile(r"[\u4E00-\u9FFF]"),
    "jpn": re.compile(r"[\u3040-\u309F\u30A0-\u30FF]"),
    "kor": re.compile(r"[\uAC00-\uD7AF\u1100-\u11FF]"),
    "rus": re.compile(r"[\u0400-\u04FF]"),
}

# Tesseract language codes mapped from script IDs
_SCRIPT_TO_LANG: Dict[str, str] = {
    "ara": "ara",
    "eng": "eng",
    "deu": "deu",
    "fra": "fra",
    "spa": "spa",
    "hin": "hin",
    "zho": "chi_sim",
    "jpn": "jpn",
    "kor": "kor",
    "rus": "rus",
}


class LanguageDetector:
    """Detect dominant scripts in text and recommend Tesseract languages.

    Usage::

        detector = LanguageDetector()
        lang_str = detector.detect("Hello مرحبا")  # → "ara+eng"
    """

    def __init__(
        self,
        min_char_ratio: float = 0.05,
        fallback_lang: str = "eng",
    ):
        """
        Args:
            min_char_ratio: Minimum fraction of total characters a script
                must contribute to be included (0.0–1.0).
            fallback_lang: Language to return when no script is detected.
        """
        if min_char_ratio < 0 or min_char_ratio > 1:
            raise ValueError(
                f"min_char_ratio must be 0.0–1.0, got {min_char_ratio}"
            )
        self.min_char_ratio = min_char_ratio
        self.fallback_lang = fallback_lang

    def detect(self, text: str) -> str:
        """Detect scripts in *text* and return a Tesseract language string.

        Args:
            text: Sample text (e.g. from a quick OCR pass).

        Returns:
            Tesseract language string like ``"ara+eng"`` or ``"eng"``.
        """
        if not text or not text.strip():
            return self.fallback_lang

        counts = self._count_scripts(text)
        total = sum(counts.values())
        if total == 0:
            return self.fallback_lang

        detected: list[str] = []
        for script, count in sorted(counts.items(), key=lambda x: -x[1]):
            if count / total >= self.min_char_ratio:
                lang = _SCRIPT_TO_LANG.get(script)
                if lang and lang not in detected:
                    detected.append(lang)

        if not detected:
            return self.fallback_lang
        return "+".join(detected)

    def detect_scripts(self, text: str) -> Dict[str, int]:
        """Return raw character counts per script.

        Args:
            text: Text to analyse.

        Returns:
            Dict mapping script IDs to character counts.
        """
        return self._count_scripts(text)

    @staticmethod
    def _count_scripts(text: str) -> Dict[str, int]:
        """Count characters matching each script pattern."""
        counts: Dict[str, int] = {}
        for script, pattern in _SCRIPT_PATTERNS.items():
            n = len(pattern.findall(text))
            if n > 0:
                counts[script] = n
        return counts

