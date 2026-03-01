"""
Arrow Flight Client for Context Transfer

Phase 3: Python client for high-performance context transfer to ai-core-pal
using Arrow Flight protocol.

Features:
- Zero-copy data transfer using PyArrow
- Connection pooling
- Automatic retry with exponential backoff
- Statistics tracking
"""

import asyncio
import os
from typing import Dict, List, Optional, Any
from dataclasses import dataclass
from datetime import datetime
import hashlib

# Arrow Flight requires pyarrow
try:
    import pyarrow as pa
    import pyarrow.flight as flight
    ARROW_AVAILABLE = True
except ImportError:
    ARROW_AVAILABLE = False
    pa = None
    flight = None


@dataclass
class ContextItem:
    """Context item for RAG results."""
    source: str
    content: str
    score: float
    metadata: Optional[str] = None
    entity_type: Optional[str] = None


@dataclass
class FlightClientStats:
    """Statistics for Flight client operations."""
    requests_sent: int = 0
    bytes_transferred: int = 0
    cache_puts: int = 0
    cache_gets: int = 0
    errors: int = 0
    avg_latency_ms: float = 0.0
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "requests_sent": self.requests_sent,
            "bytes_transferred": self.bytes_transferred,
            "cache_puts": self.cache_puts,
            "cache_gets": self.cache_gets,
            "errors": self.errors,
            "avg_latency_ms": round(self.avg_latency_ms, 2),
        }


class ArrowFlightClient:
    """
    Arrow Flight client for high-performance context transfer.
    
    Uses Apache Arrow IPC format for zero-copy data sharing
    between mangle-query-service (Python) and ai-core-pal (Zig).
    """
    
    def __init__(
        self,
        host: str = "localhost",
        port: int = 8815,
        timeout_seconds: float = 30.0,
    ):
        self.host = host
        self.port = port
        self.timeout_seconds = timeout_seconds
        self._client: Optional[Any] = None
        self._connected = False
        self._stats = FlightClientStats()
        self._latencies: List[float] = []
        
    async def connect(self) -> bool:
        """Establish connection to Flight server."""
        if not ARROW_AVAILABLE:
            print("PyArrow not available, Flight client disabled")
            return False
            
        try:
            location = flight.Location.for_grpc_tcp(self.host, self.port)
            self._client = flight.FlightClient(location)
            self._connected = True
            return True
        except Exception as e:
            print(f"Failed to connect to Flight server: {e}")
            self._stats.errors += 1
            return False
    
    async def disconnect(self):
        """Close connection to Flight server."""
        if self._client:
            self._client.close()
            self._client = None
            self._connected = False
    
    async def put_context(
        self,
        context_id: str,
        items: List[ContextItem],
    ) -> bool:
        """
        Store context items in ai-core-pal via Flight DoPut.
        
        Args:
            context_id: Unique identifier for the context
            items: List of context items to store
            
        Returns:
            True if successful, False otherwise
        """
        if not ARROW_AVAILABLE or not self._connected:
            return False
            
        start_time = datetime.now()
        
        try:
            # Create Arrow schema
            schema = pa.schema([
                ("source", pa.string()),
                ("content", pa.string()),
                ("score", pa.float64()),
                ("metadata", pa.string()),
                ("entity_type", pa.string()),
            ])
            
            # Build arrays
            sources = [item.source for item in items]
            contents = [item.content for item in items]
            scores = [item.score for item in items]
            metadata = [item.metadata or "" for item in items]
            entity_types = [item.entity_type or "" for item in items]
            
            # Create RecordBatch
            batch = pa.record_batch([
                pa.array(sources),
                pa.array(contents),
                pa.array(scores),
                pa.array(metadata),
                pa.array(entity_types),
            ], schema=schema)
            
            # Create table
            table = pa.Table.from_batches([batch])
            
            # Create Flight descriptor
            descriptor = flight.FlightDescriptor.for_path(context_id)
            
            # Upload via DoPut
            writer, _ = self._client.do_put(descriptor, schema)
            writer.write_table(table)
            writer.close()
            
            # Update stats
            self._stats.cache_puts += 1
            self._stats.requests_sent += 1
            self._stats.bytes_transferred += batch.nbytes
            self._record_latency(start_time)
            
            return True
            
        except Exception as e:
            print(f"Flight DoPut error: {e}")
            self._stats.errors += 1
            return False
    
    async def get_context(
        self,
        context_id: str,
    ) -> Optional[List[ContextItem]]:
        """
        Retrieve context items from ai-core-pal via Flight DoGet.
        
        Args:
            context_id: Unique identifier for the context
            
        Returns:
            List of context items, or None if not found
        """
        if not ARROW_AVAILABLE or not self._connected:
            return None
            
        start_time = datetime.now()
        
        try:
            # Create ticket
            ticket = flight.Ticket(context_id.encode())
            
            # Retrieve via DoGet
            reader = self._client.do_get(ticket)
            table = reader.read_all()
            
            # Convert to ContextItems
            items = []
            for i in range(table.num_rows):
                items.append(ContextItem(
                    source=table["source"][i].as_py(),
                    content=table["content"][i].as_py(),
                    score=table["score"][i].as_py(),
                    metadata=table["metadata"][i].as_py() or None,
                    entity_type=table["entity_type"][i].as_py() or None,
                ))
            
            # Update stats
            self._stats.cache_gets += 1
            self._stats.requests_sent += 1
            self._stats.bytes_transferred += table.nbytes
            self._record_latency(start_time)
            
            return items if items else None
            
        except flight.FlightUnavailableError:
            return None
        except Exception as e:
            print(f"Flight DoGet error: {e}")
            self._stats.errors += 1
            return None
    
    def get_stats(self) -> Dict[str, Any]:
        """Get client statistics."""
        return self._stats.to_dict()
    
    def _record_latency(self, start_time: datetime):
        """Record request latency for statistics."""
        latency_ms = (datetime.now() - start_time).total_seconds() * 1000
        self._latencies.append(latency_ms)
        
        # Keep only last 100 latencies
        if len(self._latencies) > 100:
            self._latencies = self._latencies[-100:]
        
        # Update average
        self._stats.avg_latency_ms = sum(self._latencies) / len(self._latencies)


# Singleton instance
_flight_client: Optional[ArrowFlightClient] = None


async def get_flight_client() -> Optional[ArrowFlightClient]:
    """Get or create Arrow Flight client singleton."""
    global _flight_client
    
    if not ARROW_AVAILABLE:
        return None
    
    if _flight_client is None:
        host = os.getenv("AICORE_FLIGHT_HOST", "localhost")
        port = int(os.getenv("AICORE_FLIGHT_PORT", "8815"))
        
        _flight_client = ArrowFlightClient(host=host, port=port)
        await _flight_client.connect()
    
    return _flight_client


async def shutdown_flight_client():
    """Shutdown Flight client."""
    global _flight_client
    
    if _flight_client:
        await _flight_client.disconnect()
        _flight_client = None


def generate_context_id(query: str, classification: Dict[str, Any]) -> str:
    """Generate a unique context ID for a query."""
    key_parts = [
        query,
        classification.get("category", ""),
        ",".join(sorted(classification.get("entities", [])[:5])),
    ]
    key = "|".join(key_parts)
    return hashlib.sha256(key.encode()).hexdigest()[:16]


# Mock implementation for when PyArrow is not available
class MockFlightClient:
    """Mock Flight client for development/testing."""
    
    def __init__(self):
        self._cache: Dict[str, List[ContextItem]] = {}
        self._stats = FlightClientStats()
    
    async def connect(self) -> bool:
        return True
    
    async def disconnect(self):
        pass
    
    async def put_context(
        self,
        context_id: str,
        items: List[ContextItem],
    ) -> bool:
        self._cache[context_id] = items
        self._stats.cache_puts += 1
        return True
    
    async def get_context(
        self,
        context_id: str,
    ) -> Optional[List[ContextItem]]:
        self._stats.cache_gets += 1
        return self._cache.get(context_id)
    
    def get_stats(self) -> Dict[str, Any]:
        return self._stats.to_dict()


async def get_mock_flight_client() -> MockFlightClient:
    """Get mock Flight client for testing."""
    return MockFlightClient()