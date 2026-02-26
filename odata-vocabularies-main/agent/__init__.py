"""
OData Vocabularies Agent Module

Provides governance-aware agents with ODPS 4.1 data product integration
for OData vocabulary queries and annotation assistance.

Note: Public documentation - AI Core OK for most queries.
"""

from .odata_vocab_agent import ODataVocabAgent, MangleEngine

__all__ = ["ODataVocabAgent", "MangleEngine"]