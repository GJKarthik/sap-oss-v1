#!/usr/bin/env python3
"""
Generate vector embeddings for OData vocabulary terms.

Phase 3.1: Vocabulary Term Embeddings
This script generates embeddings for all vocabulary terms to enable semantic search.

Usage:
    python scripts/generate_vocab_embeddings.py [--model MODEL] [--output DIR]
    
Options:
    --model MODEL    Embedding model (default: text-embedding-3-small)
    --output DIR     Output directory (default: _embeddings)
    --dry-run        Show what would be embedded without calling API
"""

import argparse
import json
import os
import sys
import hashlib
from pathlib import Path
from typing import Dict, List, Optional, Any
from dataclasses import dataclass, asdict
import xml.etree.ElementTree as ET

# Optional: For actual embedding generation
try:
    from openai import OpenAI
    HAS_OPENAI = True
except ImportError:
    HAS_OPENAI = False

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False


@dataclass
class TermEmbedding:
    """Represents a vocabulary term with its embedding."""
    vocabulary: str
    namespace: str
    term_name: str
    term_type: str
    description: str
    applies_to: List[str]
    is_experimental: bool
    embedding_text: str
    embedding: Optional[List[float]] = None
    embedding_model: Optional[str] = None
    content_hash: Optional[str] = None


@dataclass
class VocabularyIndex:
    """Index of all vocabulary embeddings."""
    version: str
    model: str
    total_terms: int
    vocabularies: Dict[str, int]
    embedding_dimensions: int
    created_at: str
    terms: Dict[str, Dict[str, Any]]


class VocabularyEmbeddingGenerator:
    """Generates embeddings for OData vocabulary terms."""
    
    NAMESPACE = "{http://docs.oasis-open.org/odata/ns/edm}"
    
    def __init__(
        self,
        vocab_dir: str = "vocabularies",
        model: str = "text-embedding-3-small",
        output_dir: str = "_embeddings"
    ):
        self.vocab_dir = Path(vocab_dir)
        self.model = model
        self.output_dir = Path(output_dir)
        self.client = OpenAI() if HAS_OPENAI else None
        self.terms: List[TermEmbedding] = []
        
    def load_all_vocabularies(self) -> None:
        """Load all vocabulary XML files and extract terms."""
        print(f"Loading vocabularies from {self.vocab_dir}...")
        
        for xml_file in sorted(self.vocab_dir.glob("*.xml")):
            vocab_name = xml_file.stem
            print(f"  Processing {vocab_name}...")
            
            try:
                tree = ET.parse(xml_file)
                root = tree.getroot()
                
                # Find Schema element
                schema = root.find(f".//{self.NAMESPACE}Schema")
                if schema is None:
                    # Try without namespace
                    schema = root.find(".//Schema")
                
                if schema is None:
                    print(f"    Warning: No Schema found in {xml_file}")
                    continue
                
                namespace = schema.get("Namespace", "")
                
                # Extract terms
                for term in schema.findall(f"{self.NAMESPACE}Term"):
                    term_data = self._extract_term(term, vocab_name, namespace)
                    if term_data:
                        self.terms.append(term_data)
                
                # Also extract ComplexType and EnumType definitions
                for complex_type in schema.findall(f"{self.NAMESPACE}ComplexType"):
                    type_data = self._extract_complex_type(complex_type, vocab_name, namespace)
                    if type_data:
                        self.terms.append(type_data)
                
                for enum_type in schema.findall(f"{self.NAMESPACE}EnumType"):
                    type_data = self._extract_enum_type(enum_type, vocab_name, namespace)
                    if type_data:
                        self.terms.append(type_data)
                        
            except ET.ParseError as e:
                print(f"    Error parsing {xml_file}: {e}")
                
        print(f"Loaded {len(self.terms)} terms from vocabularies")
    
    def _extract_term(self, term: ET.Element, vocab_name: str, namespace: str) -> Optional[TermEmbedding]:
        """Extract term information from XML element."""
        name = term.get("Name")
        if not name:
            return None
        
        term_type = term.get("Type", "")
        applies_to = term.get("AppliesTo", "").split()
        
        # Get description
        description = ""
        is_experimental = False
        
        for ann in term.findall(f"{self.NAMESPACE}Annotation"):
            ann_term = ann.get("Term", "")
            if ann_term == "Core.Description":
                description = ann.get("String", "")
            elif "Experimental" in ann_term:
                is_experimental = True
        
        # Create embedding text
        embedding_text = self._create_embedding_text(
            vocab_name, name, term_type, description, applies_to
        )
        
        return TermEmbedding(
            vocabulary=vocab_name,
            namespace=namespace,
            term_name=name,
            term_type=term_type,
            description=description,
            applies_to=applies_to,
            is_experimental=is_experimental,
            embedding_text=embedding_text,
            content_hash=self._hash_content(embedding_text)
        )
    
    def _extract_complex_type(self, ctype: ET.Element, vocab_name: str, namespace: str) -> Optional[TermEmbedding]:
        """Extract ComplexType information."""
        name = ctype.get("Name")
        if not name:
            return None
        
        # Get properties
        props = []
        for prop in ctype.findall(f"{self.NAMESPACE}Property"):
            prop_name = prop.get("Name", "")
            prop_type = prop.get("Type", "")
            props.append(f"{prop_name}:{prop_type}")
        
        description = f"Complex type with properties: {', '.join(props)}" if props else ""
        
        embedding_text = f"{vocab_name}.{name} (ComplexType): {description}"
        
        return TermEmbedding(
            vocabulary=vocab_name,
            namespace=namespace,
            term_name=name,
            term_type="ComplexType",
            description=description,
            applies_to=[],
            is_experimental=False,
            embedding_text=embedding_text,
            content_hash=self._hash_content(embedding_text)
        )
    
    def _extract_enum_type(self, etype: ET.Element, vocab_name: str, namespace: str) -> Optional[TermEmbedding]:
        """Extract EnumType information."""
        name = etype.get("Name")
        if not name:
            return None
        
        # Get members
        members = []
        for member in etype.findall(f"{self.NAMESPACE}Member"):
            member_name = member.get("Name", "")
            members.append(member_name)
        
        description = f"Enumeration with values: {', '.join(members)}" if members else ""
        
        embedding_text = f"{vocab_name}.{name} (EnumType): {description}"
        
        return TermEmbedding(
            vocabulary=vocab_name,
            namespace=namespace,
            term_name=name,
            term_type="EnumType",
            description=description,
            applies_to=[],
            is_experimental=False,
            embedding_text=embedding_text,
            content_hash=self._hash_content(embedding_text)
        )
    
    def _create_embedding_text(
        self,
        vocab: str,
        name: str,
        term_type: str,
        description: str,
        applies_to: List[str]
    ) -> str:
        """Create the text to be embedded."""
        parts = [f"{vocab}.{name}"]
        
        if term_type:
            parts.append(f"(type: {term_type})")
        
        if description:
            parts.append(f": {description}")
        
        if applies_to:
            parts.append(f" [applies to: {', '.join(applies_to)}]")
        
        return " ".join(parts)
    
    def _hash_content(self, content: str) -> str:
        """Create a hash of the content for caching."""
        return hashlib.sha256(content.encode()).hexdigest()[:16]
    
    def generate_embeddings(self, dry_run: bool = False) -> None:
        """Generate embeddings for all terms."""
        if not self.terms:
            print("No terms to embed. Run load_all_vocabularies first.")
            return
        
        if dry_run:
            print(f"\n[DRY RUN] Would generate embeddings for {len(self.terms)} terms")
            for term in self.terms[:10]:
                print(f"  - {term.vocabulary}.{term.term_name}")
            if len(self.terms) > 10:
                print(f"  ... and {len(self.terms) - 10} more")
            return
        
        if not HAS_OPENAI:
            print("OpenAI library not installed. Cannot generate embeddings.")
            print("Install with: pip install openai")
            return
        
        print(f"\nGenerating embeddings with model: {self.model}")
        
        # Batch embedding for efficiency
        batch_size = 100
        total_batches = (len(self.terms) + batch_size - 1) // batch_size
        
        for batch_idx in range(total_batches):
            start_idx = batch_idx * batch_size
            end_idx = min(start_idx + batch_size, len(self.terms))
            batch = self.terms[start_idx:end_idx]
            
            print(f"  Processing batch {batch_idx + 1}/{total_batches} ({len(batch)} terms)...")
            
            texts = [term.embedding_text for term in batch]
            
            try:
                response = self.client.embeddings.create(
                    input=texts,
                    model=self.model
                )
                
                for i, embedding_data in enumerate(response.data):
                    batch[i].embedding = embedding_data.embedding
                    batch[i].embedding_model = self.model
                    
            except Exception as e:
                print(f"    Error generating embeddings: {e}")
                # Generate placeholder embeddings for offline use
                for term in batch:
                    term.embedding = self._generate_placeholder_embedding(term.embedding_text)
                    term.embedding_model = "placeholder"
        
        print(f"Generated embeddings for {len(self.terms)} terms")
    
    def _generate_placeholder_embedding(self, text: str, dims: int = 1536) -> List[float]:
        """Generate a deterministic placeholder embedding for testing."""
        import hashlib
        import struct
        
        # Create a deterministic hash-based embedding
        h = hashlib.sha256(text.encode()).digest()
        
        # Repeat hash to fill dimensions
        embedding = []
        for i in range(dims):
            idx = i % 32
            val = h[idx] / 255.0 - 0.5  # Normalize to [-0.5, 0.5]
            embedding.append(val)
        
        # Normalize to unit length
        if HAS_NUMPY:
            arr = np.array(embedding)
            arr = arr / np.linalg.norm(arr)
            return arr.tolist()
        else:
            mag = sum(x*x for x in embedding) ** 0.5
            return [x / mag for x in embedding]
    
    def save_embeddings(self) -> None:
        """Save embeddings to output directory."""
        self.output_dir.mkdir(parents=True, exist_ok=True)
        
        # Create index
        vocab_counts = {}
        terms_dict = {}
        
        for term in self.terms:
            vocab_counts[term.vocabulary] = vocab_counts.get(term.vocabulary, 0) + 1
            
            key = f"{term.vocabulary}.{term.term_name}"
            terms_dict[key] = {
                "vocabulary": term.vocabulary,
                "namespace": term.namespace,
                "term_name": term.term_name,
                "term_type": term.term_type,
                "description": term.description,
                "applies_to": term.applies_to,
                "is_experimental": term.is_experimental,
                "content_hash": term.content_hash
            }
        
        from datetime import datetime
        
        index = {
            "version": "1.0.0",
            "model": self.model,
            "total_terms": len(self.terms),
            "vocabularies": vocab_counts,
            "embedding_dimensions": len(self.terms[0].embedding) if self.terms and self.terms[0].embedding else 1536,
            "created_at": datetime.now().isoformat(),
            "terms": terms_dict
        }
        
        # Save index
        index_path = self.output_dir / "vocabulary_index.json"
        with open(index_path, "w") as f:
            json.dump(index, f, indent=2)
        print(f"Saved index to {index_path}")
        
        # Save embeddings (separate file for size)
        embeddings = {}
        for term in self.terms:
            key = f"{term.vocabulary}.{term.term_name}"
            if term.embedding:
                embeddings[key] = {
                    "embedding": term.embedding,
                    "model": term.embedding_model,
                    "text": term.embedding_text
                }
        
        embeddings_path = self.output_dir / "vocabulary_embeddings.json"
        with open(embeddings_path, "w") as f:
            json.dump(embeddings, f)
        print(f"Saved embeddings to {embeddings_path}")
        
        # Also save in numpy format for faster loading
        if HAS_NUMPY and self.terms and self.terms[0].embedding:
            keys = []
            vectors = []
            for term in self.terms:
                if term.embedding:
                    keys.append(f"{term.vocabulary}.{term.term_name}")
                    vectors.append(term.embedding)
            
            np.save(self.output_dir / "embedding_keys.npy", keys)
            np.save(self.output_dir / "embedding_vectors.npy", vectors)
            print(f"Saved numpy arrays for fast loading")
        
        print(f"\nEmbedding generation complete!")
        print(f"  Total terms: {len(self.terms)}")
        print(f"  Vocabularies: {len(vocab_counts)}")
        print(f"  Output directory: {self.output_dir}")


def main():
    parser = argparse.ArgumentParser(
        description="Generate embeddings for OData vocabulary terms"
    )
    parser.add_argument(
        "--model",
        default="text-embedding-3-small",
        help="Embedding model to use"
    )
    parser.add_argument(
        "--output",
        default="_embeddings",
        help="Output directory for embeddings"
    )
    parser.add_argument(
        "--vocab-dir",
        default="vocabularies",
        help="Directory containing vocabulary XML files"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be embedded without calling API"
    )
    parser.add_argument(
        "--placeholder",
        action="store_true",
        help="Generate placeholder embeddings (no API call)"
    )
    
    args = parser.parse_args()
    
    # Change to script directory
    script_dir = Path(__file__).parent.parent
    os.chdir(script_dir)
    
    generator = VocabularyEmbeddingGenerator(
        vocab_dir=args.vocab_dir,
        model=args.model,
        output_dir=args.output
    )
    
    generator.load_all_vocabularies()
    
    if args.placeholder:
        # Generate placeholder embeddings
        print("\nGenerating placeholder embeddings...")
        for term in generator.terms:
            term.embedding = generator._generate_placeholder_embedding(term.embedding_text)
            term.embedding_model = "placeholder"
        generator.save_embeddings()
    elif args.dry_run:
        generator.generate_embeddings(dry_run=True)
    else:
        generator.generate_embeddings()
        generator.save_embeddings()


if __name__ == "__main__":
    main()