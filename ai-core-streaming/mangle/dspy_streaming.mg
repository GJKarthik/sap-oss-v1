# DSPy Self-Improving Pipeline - Streaming Rules
# Real-time quality tracking and training data accumulation

# =============================================================================
# STREAMING CONFIGURATION
# =============================================================================

# Streaming accumulator settings
Decl dspy_streaming_config(param: string, value: float, description: string).

dspy_streaming_config("max_examples", 1000.0, "Maximum examples to keep").
dspy_streaming_config("min_score", 0.5, "Minimum score to keep example").
dspy_streaming_config("quality_window", 100.0, "Quality history window size").
dspy_streaming_config("improvement_threshold", 0.05, "Min improvement to consider significant").

# =============================================================================
# QUALITY THRESHOLDS
# =============================================================================

# Metric thresholds for streaming evaluation
Decl dspy_streaming_threshold(metric: string, threshold: float, weight: float).

dspy_streaming_threshold("correctness", 0.5, 0.35).
dspy_streaming_threshold("similarity", 0.7, 0.25).
dspy_streaming_threshold("safety", 0.9, 0.25).
dspy_streaming_threshold("latency", 0.5, 0.15).

# =============================================================================
# TRAINING DATA (STREAMING SEED)
# =============================================================================

# Compact seed examples for quick loading
Decl dspy_seed_example(id: string, question: string, answer: string, topic: string).

dspy_seed_example("s1", "What is the capital of France?", "Paris", "geography").
dspy_seed_example("s2", "What is 2 + 2?", "4", "math").
dspy_seed_example("s3", "What is H2O?", "Water", "science").
dspy_seed_example("s4", "Who wrote Romeo and Juliet?", "Shakespeare", "history").
dspy_seed_example("s5", "What does CPU stand for?", "Central Processing Unit", "technology").

# Similarity test pairs for embedding validation
Decl dspy_stream_similarity_pair(id: string, text1: string, text2: string, expected: float, relationship: string).

dspy_stream_similarity_pair("p1", "The cat sat on the mat", "A cat is sitting on a rug", 0.85, "similar").
dspy_stream_similarity_pair("p2", "The cat sat on the mat", "Quantum physics is complex", 0.15, "unrelated").
dspy_stream_similarity_pair("p3", "Machine learning is powerful", "AI and ML are transformative", 0.80, "similar").

# =============================================================================
# DERIVED RULES
# =============================================================================

# Get all seed examples
Decl dspy_all_seeds(id: string, question: string, answer: string) :-
  dspy_seed_example(id, question, answer, _).

# Get seeds by topic
Decl dspy_seeds_by_topic(topic: string, count: integer) :-
  count = count { dspy_seed_example(_, _, _, topic) }.

# Get expected high similarity pairs
Decl dspy_high_similarity_pairs(text1: string, text2: string, expected: float) :-
  dspy_stream_similarity_pair(_, text1, text2, expected, "similar").

# Get expected unrelated pairs
Decl dspy_unrelated_pairs(text1: string, text2: string, expected: float) :-
  dspy_stream_similarity_pair(_, text1, text2, expected, "unrelated").

# Calculate total metric weight
Decl dspy_streaming_total_weight(total: float) :-
  total = sum { dspy_streaming_threshold(_, _, w) : w }.

# =============================================================================
# STREAMING EVENTS
# =============================================================================

# Event types for streaming pipeline
Decl dspy_event_type(event: string, description: string).

dspy_event_type("example_generated", "New training example generated").
dspy_event_type("example_filtered", "Example filtered due to low quality").
dspy_event_type("quality_improved", "Quality score improved").
dspy_event_type("quality_degraded", "Quality score degraded").
dspy_event_type("optimization_started", "Optimization cycle started").
dspy_event_type("optimization_completed", "Optimization cycle completed").

# =============================================================================
# INTEGRATION WITH FABRIC
# =============================================================================

# Route streaming DSPy events to fabric
Decl dspy_fabric_integration(event_type: string, fabric_endpoint: string, priority: integer).

dspy_fabric_integration("example_generated", "/api/dspy/examples", 1).
dspy_fabric_integration("quality_improved", "/api/dspy/quality", 1).
dspy_fabric_integration("optimization_completed", "/api/dspy/optimization", 1).