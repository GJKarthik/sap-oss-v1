# ToonSPy - DSPy with TOON for SAP AI Core

ToonSPy is a DSPy-style declarative AI programming framework optimized for TOON output format and SAP AI Core deployments.

## Overview

ToonSPy combines three technologies:

| Technology | Role | Benefit |
|------------|------|---------|
| **DSPy Patterns** | Declarative signatures, modules | Simplified LLM programming |
| **TOON Format** | Token-efficient output | 40-60% token savings |
| **Mangle Rules** | Schema validation | Type-safe outputs |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       ToonSPy                               │
├─────────────────────────────────────────────────────────────┤
│  Mojo API Layer                                             │
│  ├── Signature - Define input/output schemas                │
│  ├── Predict - Basic LLM prediction                         │
│  ├── ChainOfThought - Reasoning with steps                  │
│  ├── ReAct - Tool-using agents                              │
│  └── AICoreAdapter - SAP AI Core integration                │
├─────────────────────────────────────────────────────────────┤
│  Mangle Logic Layer                                         │
│  ├── dspy_modules.mg - Prompt generation rules              │
│  └── aicore_schemas.mg - Validation rules                   │
├─────────────────────────────────────────────────────────────┤
│  Zig Core Layer                                             │
│  └── toon.zig - High-performance TOON parser                │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Basic Prediction

```mojo
from toonspy import Signature, InputField, OutputField, Predict, AICoreAdapter

# Define signature
var sig = Signature(description="Classify the sentiment of text")
sig.add_input(InputField(name="text", desc="Text to classify"))
sig.add_output(OutputField(
    name="sentiment",
    field_type="enum",
    enum_values=List("positive", "negative", "neutral")
))
sig.add_output(OutputField(
    name="confidence",
    field_type="float",
    range_min=0.0,
    range_max=1.0
))

# Create predictor with AI Core
var lm = AICoreAdapter()
var classifier = Predict(sig, lm)

# Run prediction
var result = classifier.call({"text": "I love this product!"})
# Output: {"sentiment": "positive", "confidence": "0.95"}
```

### 2. Chain of Thought

```mojo
from toonspy import Signature, ChainOfThought, AICoreAdapter

var sig = Signature(description="Solve the math problem step by step")
sig.add_input(InputField(name="problem"))
sig.add_output(OutputField(name="answer"))

var cot = ChainOfThought(sig, AICoreAdapter())
var result = cot.call({"problem": "If a train travels 60 mph for 2.5 hours, how far does it go?"})

# Output:
# {
#   "reasoning": "speed_is_60mph|time_is_2.5hours|distance=speed*time|60*2.5=150",
#   "answer": "150 miles"
# }
```

### 3. ReAct Agent

```mojo
from toonspy import Signature, ReAct, Tool, AICoreAdapter

var sig = Signature(description="Answer questions using available tools")
sig.add_input(InputField(name="question"))
sig.add_output(OutputField(name="answer"))

var agent = ReAct(sig, AICoreAdapter())
agent.add_tool(Tool("search", "Search the web", List("query")))
agent.add_tool(Tool("calculate", "Do math", List("expression")))

fn my_tool_executor(name: String, input: String) -> String:
    if name == "search":
        return "France population: 67 million"
    elif name == "calculate":
        return eval(input)
    return "Unknown tool"

var result = agent.call(
    {"question": "What is the population of France?"},
    my_tool_executor
)
# Output: {"answer": "67 million", "steps": "2"}
```

## TOON Output Format

ToonSPy outputs use TOON format instead of JSON:

```
# JSON (47 tokens):
{"sentiment": "positive", "confidence": 0.95, "keywords": ["love", "great"]}

# TOON (18 tokens):
sentiment:positive confidence:0.95 keywords:love|great

# Savings: ~62%
```

### TOON Rules

| Feature | TOON Syntax | Example |
|---------|-------------|---------|
| Key-value | `key:value` | `name:John` |
| String (simple) | No quotes | `city:NYC` |
| String (spaces) | Quoted | `msg:"Hello World"` |
| Number | Direct | `age:30` |
| Boolean | `true/false` | `active:true` |
| Null | `~` | `value:~` |
| Array | Pipe-separated | `items:a\|b\|c` |
| Nested | Space-separated | `user:name:John age:30` |

## Signatures

### Pre-defined Signatures

ToonSPy includes common signatures in `mangle/dspy_modules.mg`:

```mangle
% Sentiment Classification
signature(sentiment_classification,
    "Classify the sentiment of the given text.",
    [input_field(text, "Text to analyze", true)],
    [output_field(sentiment, enum, ["positive", "negative", "neutral"]),
     output_field(confidence, float, range(0.0, 1.0))]).

% Log Analysis (rustshimmy-specific)
signature(log_analysis,
    "Analyze log entries and extract structured information.",
    [input_field(log_entry, "Raw log entry", true)],
    [output_field(severity, enum, ["debug", "info", "warn", "error", "critical"]),
     output_field(category, string, none),
     output_field(message, string, none),
     output_field(action, string, none)]).
```

### Custom Signatures

```mojo
var sig = Signature(
    name="my_task",
    description="Extract product information",
    mangle_rules="path/to/custom_rules.mg"
)

sig.add_input(InputField(name="product_page", desc="HTML content"))
sig.add_output(OutputField(name="name", field_type="string"))
sig.add_output(OutputField(name="price", field_type="float"))
sig.add_output(OutputField(name="features", field_type="array"))
```

## SAP AI Core Integration

### Environment Variables

```bash
export AICORE_ENDPOINT="https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com"
export AICORE_DEPLOYMENT_ID="d1234567"
export AICORE_RESOURCE_GROUP="default"
export AICORE_CLIENT_ID="your-client-id"
export AICORE_CLIENT_SECRET="your-client-secret"
export AICORE_TOKEN_URL="https://your-subdomain.authentication.us10.hana.ondemand.com/oauth/token"
```

### Explicit Configuration

```mojo
from toonspy import AICoreAdapter, AICoreConfig

var config = AICoreConfig(
    endpoint="https://api.ai.prod.us-east-1.aws.ml.hana.ondemand.com",
    deployment_id="d1234567",
    resource_group="default",
    model_name="gpt-4",
    max_tokens=512,
    temperature=0.1
)

var lm = AICoreAdapter(config)
```

### Deployment Scripts

Use the existing deployment scripts:

```bash
# Create AI Core scenario for ToonSPy
./scripts/create_aicore_scenario.sh

# Deploy ToonSPy-enabled model
./scripts/deploy_to_aicore.sh

# Test the deployment
./scripts/test_aicore_deployment.sh
```

## Mangle Validation

### Schema Validation

```mangle
% Validate TOON output from AI Core
valid_toon_output(ToonStr) :-
    toon:parse(ToonStr, Parsed),
    fn:is_object(Parsed).

% Validate log analysis output
valid_log_analysis(ToonStr) :-
    toon:parse(ToonStr, Parsed),
    fn:get(Parsed, "severity", Sev),
    log_severity(Sev),
    fn:has_key(Parsed, "category"),
    fn:has_key(Parsed, "message").
```

### Error Recovery

```mangle
% Retry strategy based on error type
retry_strategy("rate_limit", exponential_backoff, 3).
retry_strategy("timeout", linear_backoff, 2).
retry_strategy("parse_error", immediate, 1).
```

## Token Savings

| Module | JSON Tokens | TOON Tokens | Savings |
|--------|-------------|-------------|---------|
| Predict | ~40 | ~16 | 60% |
| ChainOfThought | ~120 | ~50 | 58% |
| ReAct (per step) | ~80 | ~35 | 56% |

**Annual cost reduction**: 40-60% on LLM API costs

## File Structure

```
rustshimmy-be-log-local-models/
├── mojo/toonspy/
│   ├── __init__.mojo         # Package exports
│   ├── signature.mojo        # Signature, Fields
│   ├── predict.mojo          # Predict module
│   ├── chain_of_thought.mojo # CoT module
│   ├── react.mojo            # ReAct agent
│   └── aicore.mojo           # SAP AI Core adapter
├── mangle/
│   ├── toon_rules.mg         # TOON validation
│   ├── dspy_modules.mg       # DSPy templates
│   └── aicore_schemas.mg     # AI Core schemas
├── zig/src/
│   └── toon.zig              # TOON parser
└── docs/
    ├── TOON_SPEC.md          # TOON format spec
    └── TOONSPY.md            # This file
```

## Examples

### Log Analysis Pipeline

```mojo
from toonspy import Signature, InputField, OutputField, Predict, AICoreAdapter

# Use pre-defined log analysis signature
var sig = Signature(
    description="Analyze log entries and extract structured information."
)
sig.add_input(InputField(name="log_entry"))
sig.add_output(OutputField(name="severity", field_type="enum",
    enum_values=List("debug", "info", "warn", "error", "critical")))
sig.add_output(OutputField(name="category"))
sig.add_output(OutputField(name="message"))
sig.add_output(OutputField(name="action"))

var analyzer = Predict(sig, AICoreAdapter())

# Analyze logs
var logs = [
    "ERROR 2026-02-15 22:00:00 Database connection timeout after 30s",
    "INFO 2026-02-15 22:00:01 User login successful: user@example.com",
    "WARN 2026-02-15 22:00:02 Memory usage at 85%"
]

for log in logs:
    var result = analyzer.call({"log_entry": log})
    print(result)
    # Output: severity:error category:database message:connection_timeout action:retry
```

### Batch Classification

```mojo
from toonspy import create_classification_signature, predict_batch, AICoreAdapter

var sig = create_classification_signature(
    "Classify customer feedback",
    List("positive", "negative", "neutral", "question")
)

var feedbacks = [
    {"text": "Great product, love it!"},
    {"text": "Doesn't work as expected"},
    {"text": "How do I return this?"}
]

var results = predict_batch(sig, feedbacks, AICoreAdapter())
# Results: [{"category": "positive"}, {"category": "negative"}, {"category": "question"}]
```

## API Reference

### Signature

```mojo
struct Signature:
    fn __init__(description: String, name: String, mangle_rules: String)
    fn add_input(field: InputField)
    fn add_output(field: OutputField)
    fn generate_toon_prompt() -> String
    fn validate_inputs(inputs: Dict[String, String]) -> Bool
```

### Predict

```mojo
struct Predict:
    fn __init__(signature: Signature, lm: AICoreAdapter)
    fn add_demo(demo: Dict[String, String])
    fn call(inputs: Dict[String, String]) -> Dict[String, String]
```

### ChainOfThought

```mojo
struct ChainOfThought:
    fn __init__(signature: Signature, lm: AICoreAdapter)
    fn call(inputs: Dict[String, String]) -> Dict[String, String]
    fn get_reasoning_steps(result: Dict) -> List[String]
```

### ReAct

```mojo
struct ReAct:
    fn __init__(signature: Signature, lm: AICoreAdapter, max_steps: Int)
    fn add_tool(tool: Tool)
    fn call(inputs: Dict, tool_executor: fn) -> Dict[String, String]
    fn get_history() -> List[ReActStep]
```

### AICoreAdapter

```mojo
struct AICoreAdapter:
    fn __init__(config: AICoreConfig)
    fn complete(prompt: String, system_prompt: String) -> String
    fn complete_with_retry(prompt: String, max_retries: Int) -> String
```

## Version

ToonSPy v0.1.0 for SAP AI Core