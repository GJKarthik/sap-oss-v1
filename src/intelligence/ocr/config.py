"""Configuration file loader for the OCR module.

Supports YAML and TOML formats.  The configuration file maps 1:1 to
``ArabicOCRService`` constructor parameters.

Example YAML::

    languages: "ara+eng"
    dpi: 300
    max_workers: 2
    preprocessing:
      enable_grayscale: true
      enable_denoise: true
    postprocessing:
      enable_whitespace_norm: true
    min_confidence: 70.0
    enable_cache: true

Usage::

    from intelligence.ocr.config import load_config, service_from_config
    config = load_config("ocr_config.yaml")
    service = service_from_config(config)
"""

import logging
import os
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)


def load_config(path: str) -> Dict[str, Any]:
    """Load configuration from a YAML or TOML file.

    Args:
        path: Path to the config file.

    Returns:
        Configuration dictionary.

    Raises:
        FileNotFoundError: If the file does not exist.
        ValueError: If the file format is unsupported.
        RuntimeError: If the required parser is not installed.
    """
    if not os.path.exists(path):
        raise FileNotFoundError(f"Config file not found: {path}")

    ext = os.path.splitext(path)[1].lower()

    if ext in (".yaml", ".yml"):
        try:
            import yaml
        except ImportError:
            raise RuntimeError(
                "PyYAML is required for YAML config files.  "
                "Install with: pip install pyyaml"
            )
        with open(path, "r") as f:
            return yaml.safe_load(f) or {}

    elif ext == ".toml":
        try:
            import tomllib  # Python 3.11+
        except ImportError:
            try:
                import tomli as tomllib  # type: ignore[no-redef]
            except ImportError:
                raise RuntimeError(
                    "tomli is required for TOML config files on Python <3.11.  "
                    "Install with: pip install tomli"
                )
        with open(path, "rb") as f:
            return tomllib.load(f)

    else:
        raise ValueError(
            f"Unsupported config file format '{ext}'.  Use .yaml or .toml."
        )


def service_from_config(
    config: Dict[str, Any],
) -> "ArabicOCRService":
    """Create an ArabicOCRService from a configuration dictionary.

    The config dict keys match the ``ArabicOCRService.__init__`` parameters.
    Nested dicts ``preprocessing`` and ``postprocessing`` are converted to
    their dataclass equivalents.

    Args:
        config: Configuration dictionary (e.g. from ``load_config``).

    Returns:
        Configured ArabicOCRService instance.
    """
    from .arabic_ocr_service import ArabicOCRService
    from .postprocessing import PostprocessingConfig
    from .preprocessing import PreprocessingConfig

    kwargs = dict(config)

    # Convert nested configs to dataclass instances
    if "preprocessing" in kwargs and isinstance(kwargs["preprocessing"], dict):
        kwargs["preprocessing"] = PreprocessingConfig(**kwargs["preprocessing"])
    if "postprocessing" in kwargs and isinstance(kwargs["postprocessing"], dict):
        kwargs["postprocessing"] = PostprocessingConfig(**kwargs["postprocessing"])

    return ArabicOCRService(**kwargs)

