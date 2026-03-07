"""
Speculative Executor for Mangle Query Service.

Executes multiple resolution paths in parallel when confidence is low,
returning the first successful result. Provides 30-50% latency reduction
for ambiguous queries.
"""

import asyncio
import os
from typing import Any, Callable, Dict, List, Optional, Tuple
from dataclasses import dataclass
from datetime import datetime
import httpx

# Configuration
SPECULATIVE_THRESHOLD = int(os.getenv("SPECULATIVE_THRESHOLD", "75"))
SPECULATIVE_TIMEOUT = float(os.getenv("SPECULATIVE_TIMEOUT", "3.0"))
SPECULATIVE_MIN_SCORE = int(os.getenv("SPECULATIVE_MIN_SCORE", "60"))


@dataclass
class ResolutionResult:
    """Result from a speculative resolution attempt."""
    route: str
    context: Any
    score: float
    latency_ms: float
    success: bool
    error: Optional[str] = None


class SpeculativeExecutor:
    """
    Execute multiple resolution paths speculatively.
    
    When query classification confidence is low, starts multiple
    resolution paths in parallel and returns the first successful result.
    """
    
    # Route fallback mappings based on primary route
    SPECULATIVE_CANDIDATES = {
        "hana_analytical": ["es_aggregation", "rag_enriched"],
        "hana_hierarchy": ["rag_enriched", "llm_fallback"],
        "es_factual": ["rag_enriched", "es_aggregation"],
        "es_aggregation": ["hana_analytical", "rag_enriched"],
        "rag_enriched": ["es_factual", "llm_fallback"],
        "metadata": ["rag_enriched"],
        "llm_fallback": [],
        "cache": [],  # Cache hits don't need speculation
    }
    
    def __init__(
        self,
        resolver_func: Optional[Callable] = None,
        threshold: int = SPECULATIVE_THRESHOLD,
        timeout: float = SPECULATIVE_TIMEOUT,
        min_score: int = SPECULATIVE_MIN_SCORE,
    ):
        """
        Initialize speculative executor.
        
        Args:
            resolver_func: Async function that resolves a query given route
            threshold: Confidence threshold below which to use speculation
            timeout: Maximum time to wait for speculative results
            min_score: Minimum score to accept a speculative result
        """
        self.resolver_func = resolver_func
        self.threshold = threshold
        self.timeout = timeout
        self.min_score = min_score
        
        # Stats tracking
        self.stats = {
            "total_speculative": 0,
            "early_wins": 0,
            "fallback_wins": 0,
            "timeouts": 0,
        }
    
    def set_resolver(self, resolver_func: Callable) -> None:
        """Set the resolver function after initialization."""
        self.resolver_func = resolver_func
    
    async def resolve_speculative(
        self,
        query: str,
        classification: Dict[str, Any],
    ) -> ResolutionResult:
        """
        Execute speculative resolution based on classification confidence.
        
        If confidence >= threshold: Execute only the primary route
        If confidence < threshold: Execute primary + fallback routes in parallel
        
        Returns the first successful result with score >= min_score.
        """
        confidence = classification.get("confidence", 50)
        primary_route = classification.get("route", "llm_fallback")
        
        # Handle enum types
        if hasattr(primary_route, "value"):
            primary_route = primary_route.value
        
        # High confidence: single path execution
        if confidence >= self.threshold:
            return await self._resolve_single(query, classification, primary_route)
        
        # Low confidence: speculative parallel execution
        return await self._resolve_parallel(query, classification, primary_route)
    
    async def _resolve_single(
        self,
        query: str,
        classification: Dict[str, Any],
        route: str,
    ) -> ResolutionResult:
        """Execute single resolution path."""
        start = datetime.now()
        
        try:
            if self.resolver_func is None:
                return ResolutionResult(
                    route=route,
                    context=None,
                    score=0,
                    latency_ms=0,
                    success=False,
                    error="No resolver function configured"
                )
            
            result = await asyncio.wait_for(
                self.resolver_func(query, classification, route),
                timeout=self.timeout
            )
            
            latency = (datetime.now() - start).total_seconds() * 1000
            
            return ResolutionResult(
                route=route,
                context=result.get("context"),
                score=result.get("score", 70),
                latency_ms=latency,
                success=True,
            )
        except asyncio.TimeoutError:
            self.stats["timeouts"] += 1
            return ResolutionResult(
                route=route,
                context=None,
                score=0,
                latency_ms=self.timeout * 1000,
                success=False,
                error="Timeout"
            )
        except Exception as e:
            latency = (datetime.now() - start).total_seconds() * 1000
            return ResolutionResult(
                route=route,
                context=None,
                score=0,
                latency_ms=latency,
                success=False,
                error=str(e)
            )
    
    async def _resolve_parallel(
        self,
        query: str,
        classification: Dict[str, Any],
        primary_route: str,
    ) -> ResolutionResult:
        """
        Execute multiple resolution paths in parallel.
        
        Returns first successful result with score >= min_score,
        or best result if none meet threshold.
        """
        self.stats["total_speculative"] += 1
        
        # Determine candidates
        candidates = self._select_candidates(primary_route, classification)
        
        if not candidates:
            return await self._resolve_single(query, classification, primary_route)
        
        # Create tasks for all candidates
        tasks = {}
        for route in candidates:
            task = asyncio.create_task(
                self._resolve_with_tracking(query, classification, route)
            )
            tasks[task] = route
        
        pending = set(tasks.keys())
        results: List[ResolutionResult] = []
        winner: Optional[ResolutionResult] = None
        
        # Wait for results with early termination
        start = datetime.now()
        remaining_timeout = self.timeout
        
        while pending and remaining_timeout > 0:
            done, pending = await asyncio.wait(
                pending,
                timeout=min(0.1, remaining_timeout),
                return_when=asyncio.FIRST_COMPLETED
            )
            
            for task in done:
                try:
                    result = task.result()
                    results.append(result)
                    
                    # Check for early winner
                    if result.success and result.score >= self.min_score:
                        winner = result
                        self.stats["early_wins"] += 1
                        
                        # Cancel remaining tasks
                        for p in pending:
                            p.cancel()
                        
                        return winner
                except Exception as e:
                    route = tasks.get(task, "unknown")
                    results.append(ResolutionResult(
                        route=route,
                        context=None,
                        score=0,
                        latency_ms=(datetime.now() - start).total_seconds() * 1000,
                        success=False,
                        error=str(e)
                    ))
            
            remaining_timeout = self.timeout - (datetime.now() - start).total_seconds()
        
        # Cancel any remaining tasks
        for task in pending:
            task.cancel()
        
        # No early winner - return best result
        successful = [r for r in results if r.success]
        
        if successful:
            best = max(successful, key=lambda r: r.score)
            if best.route != primary_route:
                self.stats["fallback_wins"] += 1
            return best
        
        # All failed - return primary route failure or first failure
        primary_result = next(
            (r for r in results if r.route == primary_route),
            results[0] if results else None
        )
        
        if primary_result:
            return primary_result
        
        return ResolutionResult(
            route=primary_route,
            context=None,
            score=0,
            latency_ms=self.timeout * 1000,
            success=False,
            error="All resolution paths failed"
        )
    
    async def _resolve_with_tracking(
        self,
        query: str,
        classification: Dict[str, Any],
        route: str,
    ) -> ResolutionResult:
        """Resolve with timing and error tracking."""
        return await self._resolve_single(query, classification, route)
    
    def _select_candidates(
        self,
        primary_route: str,
        classification: Dict[str, Any],
    ) -> List[str]:
        """
        Select candidate routes for speculative execution.
        
        Includes primary route plus fallbacks based on query characteristics.
        """
        candidates = [primary_route]
        
        # Add route-specific fallbacks
        fallbacks = self.SPECULATIVE_CANDIDATES.get(primary_route, [])
        confidence = classification.get("confidence", 50)
        
        # More fallbacks for lower confidence
        if confidence < 60:
            candidates.extend(fallbacks[:2])
        elif confidence < 70:
            candidates.extend(fallbacks[:1])
        
        # Deduplicate while preserving order
        seen = set()
        unique = []
        for c in candidates:
            if c not in seen:
                seen.add(c)
                unique.append(c)
        
        return unique[:3]  # Max 3 parallel paths
    
    def get_stats(self) -> Dict[str, Any]:
        """Get speculative execution statistics."""
        total = self.stats["total_speculative"]
        if total == 0:
            return {**self.stats, "early_win_rate": 0, "fallback_win_rate": 0}
        
        return {
            **self.stats,
            "early_win_rate": self.stats["early_wins"] / total * 100,
            "fallback_win_rate": self.stats["fallback_wins"] / total * 100,
        }


# Singleton instance
_executor: Optional[SpeculativeExecutor] = None
_executor_lock = asyncio.Lock()


async def get_speculative_executor() -> SpeculativeExecutor:
    """Get or create the speculative executor singleton."""
    global _executor
    
    async with _executor_lock:
        if _executor is None:
            _executor = SpeculativeExecutor()
        return _executor