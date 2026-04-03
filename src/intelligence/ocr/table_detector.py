"""Advanced table detection using OpenCV line analysis.

Provides rule-based table detection that finds horizontal and vertical lines
in an image, identifies grid intersections, and extracts cell boundaries.
Falls back to heuristic-only detection when OpenCV is not available.
"""

import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

from PIL import Image

logger = logging.getLogger(__name__)


@dataclass
class CellBBox:
    """Bounding box of a single table cell."""

    row: int
    col: int
    x: int
    y: int
    w: int
    h: int


@dataclass
class GridTable:
    """A table defined by detected ruling lines."""

    rows: int
    cols: int
    cells: List[CellBBox] = field(default_factory=list)
    bbox: Optional[Tuple[int, int, int, int]] = None  # x, y, w, h


class TableDetector:
    """Detect tables in page images using OpenCV ruling-line analysis.

    When OpenCV is available the detector:
      1. Converts to grayscale and applies adaptive threshold
      2. Detects horizontal lines via a wide morphological kernel
      3. Detects vertical lines via a tall morphological kernel
      4. Combines to find intersections → grid structure
      5. Extracts cell bounding boxes from the grid

    Falls back gracefully when OpenCV is not installed.
    """

    def __init__(
        self,
        min_line_length_ratio: float = 0.15,
        merge_distance: int = 10,
    ):
        """
        Args:
            min_line_length_ratio: Minimum line length as fraction of
                image width/height to consider it a ruling line.
            merge_distance: Pixel distance below which nearby lines
                are merged into one.
        """
        self.min_line_length_ratio = min_line_length_ratio
        self.merge_distance = merge_distance

    def detect(self, image: Image.Image) -> List[GridTable]:
        """Detect grid tables in *image*.

        Args:
            image: PIL Image of a document page.

        Returns:
            List of detected GridTable objects (may be empty).
        """
        try:
            import cv2
            import numpy as np
        except ImportError:
            logger.debug("OpenCV not available — skipping line-based table detection")
            return []

        img_array = np.array(image.convert("L"))
        # Adaptive threshold → binary
        binary = cv2.adaptiveThreshold(
            img_array, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
            cv2.THRESH_BINARY_INV, 15, 4,
        )

        h_lines = self._detect_lines(binary, horizontal=True)
        v_lines = self._detect_lines(binary, horizontal=False)

        if len(h_lines) < 2 or len(v_lines) < 2:
            return []

        h_lines = self._merge_close(sorted(h_lines), self.merge_distance)
        v_lines = self._merge_close(sorted(v_lines), self.merge_distance)

        return [self._build_grid(h_lines, v_lines)]

    # ------------------------------------------------------------------

    def _detect_lines(
        self, binary: "np.ndarray", horizontal: bool
    ) -> List[int]:
        """Find horizontal or vertical ruling-line positions."""
        import cv2
        import numpy as np

        h, w = binary.shape
        if horizontal:
            klen = max(int(w * self.min_line_length_ratio), 10)
            kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (klen, 1))
        else:
            klen = max(int(h * self.min_line_length_ratio), 10)
            kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (1, klen))

        detected = cv2.morphologyEx(binary, cv2.MORPH_OPEN, kernel)
        projection = np.sum(detected, axis=1 if horizontal else 0)
        threshold = max(projection) * 0.3 if max(projection) > 0 else 0
        positions = [i for i, v in enumerate(projection) if v > threshold]
        # Reduce to unique line centres
        return self._cluster(positions, self.merge_distance)

    @staticmethod
    def _cluster(positions: List[int], dist: int) -> List[int]:
        if not positions:
            return []
        groups: List[List[int]] = [[positions[0]]]
        for p in positions[1:]:
            if p - groups[-1][-1] <= dist:
                groups[-1].append(p)
            else:
                groups.append([p])
        return [int(sum(g) / len(g)) for g in groups]

    @staticmethod
    def _merge_close(positions: List[int], dist: int) -> List[int]:
        if not positions:
            return []
        merged = [positions[0]]
        for p in positions[1:]:
            if p - merged[-1] > dist:
                merged.append(p)
        return merged

    @staticmethod
    def _build_grid(h_lines: List[int], v_lines: List[int]) -> GridTable:
        rows = len(h_lines) - 1
        cols = len(v_lines) - 1
        cells: List[CellBBox] = []
        for r in range(rows):
            for c in range(cols):
                cells.append(CellBBox(
                    row=r, col=c,
                    x=v_lines[c], y=h_lines[r],
                    w=v_lines[c + 1] - v_lines[c],
                    h=h_lines[r + 1] - h_lines[r],
                ))
        x0, y0 = v_lines[0], h_lines[0]
        bbox = (x0, y0, v_lines[-1] - x0, h_lines[-1] - y0)
        return GridTable(rows=rows, cols=cols, cells=cells, bbox=bbox)

