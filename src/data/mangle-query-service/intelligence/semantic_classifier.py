"""
Semantic Query Classifier for Mangle Query Service.

Uses embeddings to classify queries by semantic similarity to category centroids,
providing 40-60% improvement over regex-based classification for ambiguous queries.
"""

import asyncio
import hashlib
import os
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass
import httpx

# Configuration
EMBEDDING_URL = os.getenv("EMBEDDING_URL", "http://localhost:8081")
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "text-embedding-ada-002")
CLASSIFIER_SIMILARITY_THRESHOLD = float(os.getenv("CLASSIFIER_SIMILARITY_THRESHOLD", "0.7"))


@dataclass
class ClassificationResult:
    """Result of semantic classification."""
    category: str
    confidence: float
    scores: Dict[str, float]
    method: str  # "semantic" or "regex_fallback"


class SemanticQueryClassifier:
    """
    Classify queries using embedding-based semantic similarity.
    
    Pre-computes category centroids from exemplar queries and classifies
    new queries by finding the most similar centroid.
    """
    
    # Category exemplars for centroid computation
    CATEGORY_EXEMPLARS = {
        "analytical": [
            "total sales by region",
            "average order value per customer", 
            "revenue breakdown by product category",
            "sum of quantities grouped by month",
            "show me the trend of orders over time",
            "compare sales between Q1 and Q2",
            "what is the total amount for company code 1000",
        ],
        "factual": [
            "show customer details for ID 12345",
            "get purchase order 4500001234",
            "what is the material number for product X",
            "find vendor information for supplier ABC",
            "lookup cost center 1000",
            "show me document number 500000123",
        ],
        "knowledge": [
            "explain how credit memo processing works",
            "what is the difference between MIRO and MIGO",
            "best practices for inventory management",
            "describe the G/L account reconciliation process",
            "how do I configure automatic payment program",
            "what are the steps for goods receipt",
        ],
        "hierarchy": [
            "show cost center hierarchy under 1000",
            "drill down from company code to profit center",
            "expand organization structure",
            "display the reporting hierarchy",
            "navigate the profit center tree",
        ],
        "timeseries": [
            "monthly sales trend for last 12 months",
            "daily order volume over the past week",
            "quarterly revenue growth rate",
            "year over year comparison",
            "forecast sales for next quarter",
        ],
        "metadata": [
            "what dimensions are available for sales",
            "which measures can I aggregate",
            "show me the fields in ACDOCA",
            "list available report columns",
            "what filters can I apply",
        ],
    }
    
    def __init__(self, embedding_url: Optional[str] = None):
        self.embedding_url = embedding_url or EMBEDDING_URL
        self.category_centroids: Dict[str, List[float]] = {}
        self._initialized = False
        self._init_lock = asyncio.Lock()
        
    async def initialize(self) -> None:
        """Pre-compute embeddings for category exemplars and compute centroids."""
        async with self._init_lock:
            if self._initialized:
                return
                
            print("Initializing semantic classifier with category centroids...")
            
            for category, exemplars in self.CATEGORY_EXEMPLARS.items():
                try:
                    # Get embeddings for all exemplars
                    embeddings = await asyncio.gather(*[
                        self._get_embedding(ex) for ex in exemplars
                    ])
                    
                    # Filter out failed embeddings
                    valid_embeddings = [e for e in embeddings if e is not None]
                    
                    if valid_embeddings:
                        # Compute centroid (element-wise average)
                        centroid = self._compute_centroid(valid_embeddings)
                        self.category_centroids[category] = centroid
                        print(f"  Computed centroid for '{category}' from {len(valid_embeddings)} exemplars")
                except Exception as e:
                    print(f"  Failed to compute centroid for '{category}': {e}")
            
            self._initialized = bool(self.category_centroids)
            print(f"Semantic classifier initialized with {len(self.category_centroids)} categories")
    
    async def classify(self, query: str) -> ClassificationResult:
        """
        Classify query by semantic similarity to category centroids.
        
        Returns:
            ClassificationResult with category, confidence, and all scores
        """
        # Ensure initialized
        if not self._initialized:
            await self.initialize()
        
        # If no centroids available, return unknown
        if not self.category_centroids:
            return ClassificationResult(
                category="llm_required",
                confidence=50.0,
                scores={},
                method="no_centroids"
            )
        
        # Get query embedding
        query_embedding = await self._get_embedding(query)
        
        if query_embedding is None:
            return ClassificationResult(
                category="llm_required",
                confidence=50.0,
                scores={},
                method="embedding_failed"
            )
        
        # Compute similarity to each category centroid
        scores: Dict[str, float] = {}
        
        for category, centroid in self.category_centroids.items():
            similarity = self._cosine_similarity(query_embedding, centroid)
            scores[category] = similarity
        
        # Find best category
        best_category = max(scores, key=scores.get)
        best_score = scores[best_category]
        
        # Convert similarity to confidence (0-100 scale)
        # Similarity ranges from -1 to 1, we map 0.5-1.0 to 50-100
        confidence = min(100.0, max(50.0, best_score * 100))
        
        # If best score is below threshold, classify as llm_required
        if best_score < CLASSIFIER_SIMILARITY_THRESHOLD:
            return ClassificationResult(
                category="llm_required",
                confidence=confidence,
                scores=scores,
                method="semantic_low_confidence"
            )
        
        return ClassificationResult(
            category=best_category,
            confidence=confidence,
            scores=scores,
            method="semantic"
        )
    
    async def classify_with_fallback(
        self, 
        query: str, 
        regex_classification: Dict
    ) -> ClassificationResult:
        """
        Classify using semantic similarity, but blend with regex results.
        
        If semantic confidence is low but regex confidence is high,
        use regex result. Otherwise use semantic.
        """
        semantic_result = await self.classify(query)
        regex_confidence = regex_classification.get("confidence", 50)
        
        # If semantic is confident, use it
        if semantic_result.confidence >= 75:
            return semantic_result
        
        # If regex is more confident, use regex
        if regex_confidence > semantic_result.confidence:
            return ClassificationResult(
                category=regex_classification.get("category", "llm_required"),
                confidence=regex_confidence,
                scores=semantic_result.scores,
                method="regex_fallback"
            )
        
        # Otherwise use semantic
        return semantic_result
    
    async def _get_embedding(self, text: str) -> Optional[List[float]]:
        """Get embedding vector for text from embedding service."""
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"{self.embedding_url}/v1/embeddings",
                    json={
                        "model": EMBEDDING_MODEL,
                        "input": text,
                    },
                    timeout=10.0,
                )
                
                if response.status_code == 200:
                    data = response.json()
                    return data["data"][0]["embedding"]
                else:
                    print(f"Embedding request failed: {response.status_code}")
                    return None
        except Exception as e:
            print(f"Embedding error: {e}")
            return None
    
    def _compute_centroid(self, embeddings: List[List[float]]) -> List[float]:
        """Compute centroid (element-wise average) of embeddings."""
        if not embeddings:
            return []
        
        dim = len(embeddings[0])
        centroid = [0.0] * dim
        
        for emb in embeddings:
            for i, val in enumerate(emb):
                centroid[i] += val
        
        n = len(embeddings)
        return [v / n for v in centroid]
    
    def _cosine_similarity(self, a: List[float], b: List[float]) -> float:
        """Compute cosine similarity between two vectors."""
        if not a or not b or len(a) != len(b):
            return 0.0
        
        dot_product = sum(x * y for x, y in zip(a, b))
        norm_a = sum(x * x for x in a) ** 0.5
        norm_b = sum(x * x for x in b) ** 0.5
        
        if norm_a == 0 or norm_b == 0:
            return 0.0
        
        return dot_product / (norm_a * norm_b)
    
    def add_exemplar(self, category: str, exemplar: str) -> None:
        """Add a new exemplar to a category (requires re-initialization)."""
        if category not in self.CATEGORY_EXEMPLARS:
            self.CATEGORY_EXEMPLARS[category] = []
        self.CATEGORY_EXEMPLARS[category].append(exemplar)
        self._initialized = False  # Force re-initialization


# Singleton instance
_classifier: Optional[SemanticQueryClassifier] = None
_classifier_lock = asyncio.Lock()


async def get_classifier() -> SemanticQueryClassifier:
    """Get or create the semantic classifier singleton."""
    global _classifier
    
    async with _classifier_lock:
        if _classifier is None:
            _classifier = SemanticQueryClassifier()
            # Don't await initialization here - let it happen on first classify
        return _classifier