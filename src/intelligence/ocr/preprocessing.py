"""Image pre-processing pipeline for OCR quality improvement.

Provides configurable image transformations — deskewing, binarization,
noise removal, border removal, and resolution upscaling — that can be
applied before Tesseract OCR to improve recognition accuracy.

All operations use Pillow (no OpenCV dependency).
"""

import logging
from dataclasses import dataclass, field
from typing import List, Optional

from PIL import Image, ImageFilter, ImageOps

logger = logging.getLogger(__name__)

# Minimum target DPI for upscaling — images below this are scaled up
_MIN_OCR_DPI = 300


@dataclass
class PreprocessingConfig:
    """Configuration for the image pre-processing pipeline.

    Each flag enables/disables an individual step.  The steps run in a
    fixed order regardless of flag ordering:

        1. upscale  →  2. grayscale  →  3. binarize  →
        4. denoise  →  5. remove_borders  →  6. deskew

    Attributes:
        enable_grayscale: Convert to grayscale (recommended for OCR).
        enable_binarize: Apply adaptive-like thresholding to produce B&W.
        binarize_threshold: Pixel value threshold for binarization (0–255).
        enable_denoise: Apply median filter to remove salt-and-pepper noise.
        denoise_kernel_size: Kernel size for median filter (must be odd, ≥3).
        enable_border_removal: Crop uniform-colour borders.
        border_tolerance: Max per-channel difference to consider a border
            pixel as "uniform" compared to the edge colour.
        enable_upscale: Upscale low-resolution images to *target_dpi*.
        target_dpi: Target DPI for upscaling.
        enable_deskew: (Reserved) Deskew rotated scans — requires numpy.
    """

    enable_grayscale: bool = True
    enable_binarize: bool = False
    binarize_threshold: int = 128
    enable_denoise: bool = False
    denoise_kernel_size: int = 3
    enable_border_removal: bool = False
    border_tolerance: int = 10
    enable_upscale: bool = False
    target_dpi: int = _MIN_OCR_DPI
    enable_deskew: bool = False

    def __post_init__(self) -> None:
        if self.binarize_threshold < 0 or self.binarize_threshold > 255:
            raise ValueError(
                f"binarize_threshold must be 0–255, got {self.binarize_threshold}"
            )
        if self.denoise_kernel_size < 3 or self.denoise_kernel_size % 2 == 0:
            raise ValueError(
                f"denoise_kernel_size must be odd and ≥3, got {self.denoise_kernel_size}"
            )
        if self.target_dpi < 72:
            raise ValueError(
                f"target_dpi must be ≥72, got {self.target_dpi}"
            )


class ImagePreprocessor:
    """Applies a configurable pipeline of image transforms for OCR."""

    def __init__(self, config: Optional[PreprocessingConfig] = None):
        self.config = config or PreprocessingConfig()

    def process(self, image: Image.Image, source_dpi: int = 300) -> Image.Image:
        """Run the full pipeline on *image* and return the processed copy.

        Args:
            image: Input PIL Image.
            source_dpi: DPI of the source image (used for upscale decision).

        Returns:
            A new PIL Image with all enabled transforms applied.
        """
        img = image.copy()
        cfg = self.config

        # 1. Upscale
        if cfg.enable_upscale and source_dpi < cfg.target_dpi:
            img = self._upscale(img, source_dpi, cfg.target_dpi)

        # 2. Grayscale
        if cfg.enable_grayscale:
            img = self._to_grayscale(img)

        # 3. Binarize
        if cfg.enable_binarize:
            img = self._binarize(img, cfg.binarize_threshold)

        # 4. Denoise
        if cfg.enable_denoise:
            img = self._denoise(img, cfg.denoise_kernel_size)

        # 5. Border removal
        if cfg.enable_border_removal:
            img = self._remove_borders(img, cfg.border_tolerance)

        # 6. Deskew (placeholder — requires numpy)
        if cfg.enable_deskew:
            img = self._deskew(img)

        return img

    # ------------------------------------------------------------------
    # Individual transform steps
    # ------------------------------------------------------------------

    @staticmethod
    def _upscale(img: Image.Image, source_dpi: int, target_dpi: int) -> Image.Image:
        """Scale image up so effective DPI reaches *target_dpi*."""
        scale = target_dpi / source_dpi
        new_size = (int(img.width * scale), int(img.height * scale))
        logger.debug("Upscaling from %s to %s (%.1f×)", img.size, new_size, scale)
        return img.resize(new_size, Image.LANCZOS)

    @staticmethod
    def _to_grayscale(img: Image.Image) -> Image.Image:
        return img.convert("L")

    @staticmethod
    def _binarize(img: Image.Image, threshold: int) -> Image.Image:
        gray = img.convert("L") if img.mode != "L" else img
        return gray.point(lambda px: 255 if px > threshold else 0, mode="1")

    @staticmethod
    def _denoise(img: Image.Image, kernel_size: int) -> Image.Image:
        return img.filter(ImageFilter.MedianFilter(size=kernel_size))

    @staticmethod
    def _remove_borders(img: Image.Image, tolerance: int) -> Image.Image:
        """Crop uniform-colour borders using Pillow's ``ImageOps.crop``."""
        # Autocontrast + getbbox is the Pillow-native way
        if img.mode == "1":
            img = img.convert("L")
        inverted = ImageOps.invert(img.convert("RGB"))
        bbox = inverted.getbbox()
        if bbox:
            return img.crop(bbox)
        return img

    @staticmethod
    def _deskew(img: Image.Image) -> Image.Image:
        """Deskew a rotated scan.

        Strategy:
          1. If OpenCV is available, use Hough-line angle detection which
             handles larger skew angles (up to ±45°) and is more accurate.
          2. Otherwise fall back to a projection-profile sweep (±5°) that
             only requires numpy.
          3. If neither is available, return the image unchanged.
        """
        # --- Try OpenCV Hough-line approach ---
        try:
            import cv2
            import numpy as np

            gray = np.array(img.convert("L"))
            edges = cv2.Canny(gray, 50, 150, apertureSize=3)
            lines = cv2.HoughLinesP(
                edges, 1, np.pi / 180, threshold=80,
                minLineLength=gray.shape[1] // 6,
                maxLineGap=10,
            )
            if lines is not None and len(lines) > 0:
                angles = []
                for line in lines:
                    x1, y1, x2, y2 = line[0]
                    angle = np.degrees(np.arctan2(y2 - y1, x2 - x1))
                    # Only consider near-horizontal lines (within ±45°)
                    if abs(angle) < 45:
                        angles.append(angle)
                if angles:
                    median_angle = float(np.median(angles))
                    if abs(median_angle) > 0.1:
                        logger.debug(
                            "Deskew (Hough): rotating by %.2f°", -median_angle
                        )
                        return img.rotate(
                            -median_angle,
                            resample=Image.BICUBIC,
                            expand=True,
                            fillcolor=255,
                        )
            return img
        except ImportError:
            pass

        # --- Fallback: projection-profile (numpy only) ---
        try:
            import numpy as np

            best_angle = 0.0
            best_var = 0.0
            for angle_10x in range(-50, 51):
                angle = angle_10x / 10.0
                rotated = img.rotate(
                    angle, resample=Image.BICUBIC, fillcolor=255
                )
                row_sums = np.sum(
                    np.array(rotated.convert("L")), axis=1
                )
                var = float(np.var(row_sums))
                if var > best_var:
                    best_var = var
                    best_angle = angle
            if abs(best_angle) > 0.05:
                logger.debug(
                    "Deskew (projection): rotating by %.1f°", best_angle
                )
                return img.rotate(
                    best_angle, resample=Image.BICUBIC, fillcolor=255
                )
            return img
        except ImportError:
            logger.warning(
                "Neither OpenCV nor numpy installed — deskew disabled"
            )
            return img

