"""
Intelligence module for Mangle Query Service.

Phase 2 components:
- SemanticQueryClassifier: Embedding-based query classification
- SpeculativeExecutor: Parallel resolution paths
- AdaptiveRouter: Learning-based route selection
"""

from .semantic_classifier import SemanticQueryClassifier, get_classifier
from .speculative import SpeculativeExecutor, get_speculative_executor
from .model_selector import AdaptiveModelSelector, get_model_selector

__all__ = [
    "SemanticQueryClassifier",
    "get_classifier",
    "SpeculativeExecutor", 
    "get_speculative_executor",
    "AdaptiveModelSelector",
    "get_model_selector",
]