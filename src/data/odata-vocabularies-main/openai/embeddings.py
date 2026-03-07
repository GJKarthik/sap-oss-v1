"""
OpenAI Embeddings Endpoint

POST /v1/embeddings - Create embeddings
"""

import time
import uuid
import hashlib
from typing import Dict, Any, List, Optional, Union

from .models import resolve_model, is_embedding_model


def create_embedding(
    input: Union[str, List[str]],
    model: str = "text-embedding-odata",
    encoding_format: str = "float",
    dimensions: Optional[int] = None,
    user: Optional[str] = None,
    **kwargs
) -> Dict[str, Any]:
    """
    Create embeddings for text input.
    
    OpenAI-compatible request/response format.
    Generates deterministic embeddings based on vocabulary term matching.
    """
    resolved_model = resolve_model(model)
    
    if not is_embedding_model(model):
        return create_error_response(
            "invalid_request_error",
            f"Model {model} does not support embeddings"
        )
    
    # Normalize input to list
    if isinstance(input, str):
        inputs = [input]
    else:
        inputs = input
    
    # Generate embeddings for each input
    embeddings = []
    total_tokens = 0
    
    for i, text in enumerate(inputs):
        vector = generate_vocab_embedding(text, dimensions or 1536)
        tokens = estimate_tokens(text)
        total_tokens += tokens
        
        embeddings.append({
            "object": "embedding",
            "index": i,
            "embedding": vector if encoding_format == "float" else encode_base64(vector)
        })
    
    return {
        "object": "list",
        "data": embeddings,
        "model": resolved_model,
        "usage": {
            "prompt_tokens": total_tokens,
            "total_tokens": total_tokens
        }
    }


def generate_vocab_embedding(text: str, dimensions: int = 1536) -> List[float]:
    """
    Generate a deterministic embedding vector for vocabulary-related text.
    
    Uses a combination of:
    1. Vocabulary term detection (assigns specific patterns)
    2. Hash-based deterministic generation
    3. Semantic category weighting
    """
    # Normalize text
    text_lower = text.lower()
    
    # Initialize vector
    vector = [0.0] * dimensions
    
    # Vocabulary-specific patterns that influence embedding
    vocab_patterns = {
        # UI vocabulary terms
        "lineitem": {"category": "ui", "weight": 0.9, "positions": [0, 10, 20]},
        "headerinfo": {"category": "ui", "weight": 0.85, "positions": [0, 10, 30]},
        "selectionfields": {"category": "ui", "weight": 0.8, "positions": [0, 10, 40]},
        "facets": {"category": "ui", "weight": 0.75, "positions": [0, 10, 50]},
        "chart": {"category": "ui", "weight": 0.7, "positions": [0, 10, 60]},
        
        # Common vocabulary terms
        "label": {"category": "common", "weight": 0.9, "positions": [100, 110, 120]},
        "description": {"category": "common", "weight": 0.85, "positions": [100, 110, 130]},
        "text": {"category": "common", "weight": 0.8, "positions": [100, 110, 140]},
        
        # Analytics vocabulary terms
        "measure": {"category": "analytics", "weight": 0.9, "positions": [200, 210, 220]},
        "dimension": {"category": "analytics", "weight": 0.85, "positions": [200, 210, 230]},
        "aggregation": {"category": "analytics", "weight": 0.8, "positions": [200, 210, 240]},
        
        # PersonalData vocabulary terms
        "personal": {"category": "gdpr", "weight": 0.9, "positions": [300, 310, 320]},
        "sensitive": {"category": "gdpr", "weight": 0.95, "positions": [300, 310, 330]},
        "email": {"category": "gdpr", "weight": 0.7, "positions": [300, 310, 340]},
        "phone": {"category": "gdpr", "weight": 0.7, "positions": [300, 310, 350]},
        
        # HANA-specific terms
        "hana": {"category": "hana", "weight": 0.9, "positions": [400, 410, 420]},
        "calculation": {"category": "hana", "weight": 0.8, "positions": [400, 410, 430]},
        "vector": {"category": "hana", "weight": 0.85, "positions": [400, 410, 440]},
        
        # Code generation terms
        "cds": {"category": "codegen", "weight": 0.9, "positions": [500, 510, 520]},
        "graphql": {"category": "codegen", "weight": 0.85, "positions": [500, 510, 530]},
        "sql": {"category": "codegen", "weight": 0.8, "positions": [500, 510, 540]},
    }
    
    # Category base vectors (first 100 dimensions reserved for categories)
    category_offsets = {
        "ui": 0,
        "common": 100,
        "analytics": 200,
        "gdpr": 300,
        "hana": 400,
        "codegen": 500,
        "general": 600
    }
    
    matched_category = "general"
    max_weight = 0.0
    
    # Apply vocabulary patterns
    for pattern, config in vocab_patterns.items():
        if pattern in text_lower:
            weight = config["weight"]
            if weight > max_weight:
                max_weight = weight
                matched_category = config["category"]
            
            # Set pattern-specific positions
            for pos in config["positions"]:
                if pos < dimensions:
                    vector[pos] = weight
    
    # Set category marker
    cat_offset = category_offsets.get(matched_category, 600)
    if cat_offset < dimensions:
        vector[cat_offset] = 1.0
    
    # Generate hash-based values for remaining dimensions
    text_hash = hashlib.sha256(text.encode()).hexdigest()
    
    for i in range(dimensions):
        if vector[i] == 0.0:
            # Use hash to generate deterministic pseudo-random value
            hash_val = int(text_hash[(i % 64) * 2:(i % 64) * 2 + 2], 16)
            vector[i] = (hash_val / 255.0) * 0.1 - 0.05  # Small values [-0.05, 0.05]
    
    # Normalize vector
    magnitude = sum(v * v for v in vector) ** 0.5
    if magnitude > 0:
        vector = [v / magnitude for v in vector]
    
    return vector


def estimate_tokens(text: str) -> int:
    """Estimate token count (approximately 4 characters per token)"""
    return max(1, len(text) // 4)


def encode_base64(vector: List[float]) -> str:
    """Encode vector as base64 (for encoding_format="base64")"""
    import base64
    import struct
    
    # Pack as float32
    packed = struct.pack(f"{len(vector)}f", *vector)
    return base64.b64encode(packed).decode("utf-8")


def cosine_similarity(vec1: List[float], vec2: List[float]) -> float:
    """Calculate cosine similarity between two vectors"""
    dot_product = sum(a * b for a, b in zip(vec1, vec2))
    magnitude1 = sum(a * a for a in vec1) ** 0.5
    magnitude2 = sum(b * b for b in vec2) ** 0.5
    
    if magnitude1 == 0 or magnitude2 == 0:
        return 0.0
    
    return dot_product / (magnitude1 * magnitude2)


def find_similar_terms(query: str, term_embeddings: Dict[str, List[float]], top_k: int = 10) -> List[Dict]:
    """
    Find similar vocabulary terms based on embedding similarity.
    
    Args:
        query: Search query text
        term_embeddings: Dictionary mapping term names to embeddings
        top_k: Number of results to return
    
    Returns:
        List of similar terms with similarity scores
    """
    query_embedding = generate_vocab_embedding(query)
    
    similarities = []
    for term_name, term_embedding in term_embeddings.items():
        similarity = cosine_similarity(query_embedding, term_embedding)
        similarities.append({
            "term": term_name,
            "similarity": round(similarity, 4)
        })
    
    # Sort by similarity descending
    similarities.sort(key=lambda x: x["similarity"], reverse=True)
    
    return similarities[:top_k]


def batch_embed(texts: List[str], model: str = "text-embedding-odata") -> Dict[str, Any]:
    """
    Batch embedding generation for multiple texts.
    More efficient than calling create_embedding multiple times.
    """
    return create_embedding(
        input=texts,
        model=model
    )


def create_error_response(error_type: str, message: str) -> Dict[str, Any]:
    """Create OpenAI-compatible error response"""
    return {
        "error": {
            "message": message,
            "type": error_type,
            "param": None,
            "code": None
        }
    }


# Pre-computed embeddings for common vocabulary terms
VOCABULARY_TERM_EMBEDDINGS: Dict[str, List[float]] = {}


def initialize_vocabulary_embeddings():
    """
    Initialize embeddings for all vocabulary terms.
    Call this at server startup for fast similarity search.
    """
    terms = [
        "UI.LineItem",
        "UI.HeaderInfo",
        "UI.SelectionFields",
        "UI.Facets",
        "UI.Chart",
        "UI.DataField",
        "UI.FieldGroup",
        "Common.Label",
        "Common.Text",
        "Common.SemanticKey",
        "Analytics.Measure",
        "Analytics.Dimension",
        "Analytics.AggregatedProperty",
        "PersonalData.IsPotentiallyPersonal",
        "PersonalData.IsPotentiallySensitive",
        "Capabilities.FilterRestrictions",
        "Capabilities.SortRestrictions",
        "Core.Description",
        "Core.LongDescription",
        "Validation.Pattern"
    ]
    
    for term in terms:
        VOCABULARY_TERM_EMBEDDINGS[term] = generate_vocab_embedding(term)
    
    return len(VOCABULARY_TERM_EMBEDDINGS)