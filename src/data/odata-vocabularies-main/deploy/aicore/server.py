"""
OData Vocabularies - OpenAI-Compatible Assistant
KServe InferenceService for SAP BTP AI Core

Helps developers find correct OData annotations via chat.
"""

import os
import time
import json
import glob
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

PORT = int(os.getenv("PORT", "8080"))
VOCAB_DIR = os.getenv("VOCAB_DIR", "./vocabularies")


class Message(BaseModel):
    role: str
    content: str


class ChatCompletionRequest(BaseModel):
    model: str = "vocab-assistant"
    messages: List[Message]
    temperature: Optional[float] = 0.7
    max_tokens: Optional[int] = 1000


app = FastAPI(
    title="OData Vocabularies Assistant",
    description="OpenAI-compatible chat for OData annotation guidance",
    version="1.0.0"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Load vocabularies at startup
_vocabularies = {}

def load_vocabularies():
    global _vocabularies
    for vocab_file in glob.glob(f"{VOCAB_DIR}/*.json"):
        try:
            with open(vocab_file, "r") as f:
                data = json.load(f)
                name = os.path.basename(vocab_file).replace(".json", "")
                _vocabularies[name] = data
        except Exception:
            pass
    return _vocabularies


def search_vocabularies(query: str) -> List[Dict]:
    """Search vocabularies for matching terms."""
    results = []
    query_lower = query.lower()
    
    for vocab_name, vocab_data in _vocabularies.items():
        if isinstance(vocab_data, dict):
            for term_name, term_def in vocab_data.items():
                if query_lower in term_name.lower():
                    results.append({
                        "vocabulary": vocab_name,
                        "term": term_name,
                        "definition": term_def
                    })
    return results[:10]


def generate_response(messages: List[Message]) -> str:
    """Generate response based on user query and vocabulary knowledge."""
    user_query = messages[-1].content.lower() if messages else ""
    
    # Search vocabularies
    results = search_vocabularies(user_query)
    
    if results:
        response = "Based on OData vocabularies, here are relevant annotations:\n\n"
        for r in results[:5]:
            response += f"**{r['vocabulary']}.{r['term']}**\n"
            if isinstance(r['definition'], dict):
                response += f"  Type: {r['definition'].get('$Type', 'N/A')}\n"
                if 'Description' in r['definition']:
                    response += f"  Description: {r['definition']['Description']}\n"
            response += "\n"
        return response
    
    # Common annotation guidance
    if "currency" in user_query:
        return """For currency fields, use these annotations:
        
**@Measures.ISOCurrency** - Specifies the currency code property
**@Common.UnitSpecificScale** - For decimal precision

Example:
```
entity Products {
  Price: Decimal(10,2) @Measures.ISOCurrency: Currency;
  Currency: String(3);
}
```"""
    
    if "unit" in user_query or "measure" in user_query:
        return """For unit of measure fields:

**@Measures.Unit** - Specifies the unit property
**@Common.QuantityForUnit** - For quantity fields

Example:
```
entity Products {
  Weight: Decimal(10,3) @Measures.Unit: WeightUnit;
  WeightUnit: String(3);
}
```"""
    
    return "I can help you find OData annotations. Ask about specific properties like currency, unit of measure, or search for annotation terms."


@app.on_event("startup")
async def startup():
    load_vocabularies()


@app.get("/health")
@app.get("/healthz")
async def health():
    return {"status": "healthy", "timestamp": time.time(), "vocabularies_loaded": len(_vocabularies)}


@app.post("/v1/chat/completions")
async def chat_completions(request: ChatCompletionRequest):
    """OpenAI-compatible chat endpoint for vocabulary Q&A."""
    
    response_content = generate_response(request.messages)
    
    return {
        "id": f"chatcmpl-vocab-{int(time.time())}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": request.model,
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": response_content
            },
            "finish_reason": "stop"
        }],
        "usage": {
            "prompt_tokens": sum(len(m.content.split()) for m in request.messages),
            "completion_tokens": len(response_content.split()),
            "total_tokens": sum(len(m.content.split()) for m in request.messages) + len(response_content.split())
        }
    }


@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [
            {"id": "vocab-assistant", "object": "model", "owned_by": "odata-vocabularies"}
        ]
    }


@app.get("/v1/vocabularies")
async def list_vocabularies():
    """List loaded vocabularies."""
    return {
        "object": "list",
        "data": list(_vocabularies.keys())
    }


@app.get("/v1/vocabularies/{name}")
async def get_vocabulary(name: str):
    """Get vocabulary by name."""
    if name not in _vocabularies:
        raise HTTPException(status_code=404, detail=f"Vocabulary '{name}' not found")
    return _vocabularies[name]


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT)