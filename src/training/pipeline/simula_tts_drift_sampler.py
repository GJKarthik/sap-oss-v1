"""
Text-to-SQL User Population Sampler for Simula Training Pipeline.

This module implements stratified user sampling for drift detection as defined
in Chapter 18 of the Simula specification (Table 18.3: User Population Sampling).

Reference: docs/latex/specs/simula/chapters/18-text-to-sql-drift.tex
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any, Optional


@dataclass
class SamplingConfig:
    """
    Configuration for stratified user sampling per Chapter 18 Table 18.3.
    
    Attributes:
        power_user_threshold: Minimum queries/day for power user classification
        regular_user_min: Minimum queries/day for regular user classification
        new_user_window_days: Days since first seen to classify as new user
        sampling_rates: Sampling rate by user segment
        focus_metrics: Metrics to evaluate per segment
    """
    
    power_user_threshold: int = 100  # queries/day
    regular_user_min: int = 10
    new_user_window_days: int = 30
    
    sampling_rates: dict[str, float] = field(default_factory=lambda: {
        "power_user": 1.0,      # 100% - real-time
        "regular_user": 0.2,    # 20% - hourly batch
        "occasional_user": 0.05, # 5% - daily batch
        "new_user": 0.5,        # 50% - real-time
    })
    
    sampling_frequency: dict[str, str] = field(default_factory=lambda: {
        "power_user": "realtime",
        "regular_user": "hourly",
        "occasional_user": "daily",
        "new_user": "realtime",
    })
    
    focus_metrics: dict[str, list[str]] = field(default_factory=lambda: {
        "power_user": [
            "TTS-M01", "TTS-M02", "TTS-M03", "TTS-M04",
            "TTS-M05", "TTS-M06", "TTS-M07", "TTS-M08",
            "TTS-M09", "TTS-M10", "TTS-M11", "TTS-M12",
        ],  # All metrics
        "regular_user": ["TTS-M05", "TTS-M06", "TTS-M09", "TTS-M10"],
        "occasional_user": ["TTS-M09", "TTS-M10"],
        "new_user": ["TTS-M06", "TTS-M08"],  # Focus on ambiguity
    })


@dataclass
class UserProfile:
    """
    User profile for drift sampling classification.
    
    Attributes:
        user_id: Unique user identifier
        segment: Current segment classification
        first_seen_at: Timestamp of first query
        last_query_at: Timestamp of most recent query
        query_count_total: Total queries all time
        query_count_7d: Queries in last 7 days
        avg_daily_queries: Average queries per day (7-day window)
        sample_rate: Current sampling rate for this user
    """
    
    user_id: str
    segment: str = "unknown"
    first_seen_at: Optional[datetime] = None
    last_query_at: Optional[datetime] = None
    query_count_total: int = 0
    query_count_7d: int = 0
    avg_daily_queries: float = 0.0
    sample_rate: float = 0.2  # Default to regular user rate
    
    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for storage."""
        return {
            "user_id": self.user_id,
            "segment": self.segment,
            "first_seen_at": self.first_seen_at.isoformat() if self.first_seen_at else None,
            "last_query_at": self.last_query_at.isoformat() if self.last_query_at else None,
            "query_count_total": self.query_count_total,
            "query_count_7d": self.query_count_7d,
            "avg_daily_queries": self.avg_daily_queries,
            "sample_rate": self.sample_rate,
        }


class UserPopulationSampler:
    """
    Stratified sampling for drift detection across user populations.
    
    This class implements the user population sampling strategy described
    in Chapter 18 of the Simula specification. It classifies users into
    four segments and applies different sampling rates:
    
    - Power Users (>100 queries/day): 100% sampling, real-time
    - Regular Users (10-100/day): 20% sampling, hourly
    - Occasional Users (<10/day): 5% sampling, daily
    - New Users (first 30 days): 50% sampling, real-time
    
    Example:
        sampler = UserPopulationSampler()
        
        # Record each query
        sampler.record_query(user_id)
        
        # Check if query should be sampled
        if sampler.should_sample(user_id):
            await evaluate_drift_metrics(prompt, sql)
    """
    
    def __init__(self, config: Optional[SamplingConfig] = None):
        """
        Initialize the user population sampler.
        
        Args:
            config: Optional sampling configuration (uses defaults if not provided)
        """
        self.config = config or SamplingConfig()
        self._user_profiles: dict[str, UserProfile] = {}
        self._query_history: dict[str, list[datetime]] = {}
    
    def record_query(self, user_id: str, timestamp: Optional[datetime] = None) -> UserProfile:
        """
        Record a query from a user and update their profile.
        
        Args:
            user_id: User identifier
            timestamp: Query timestamp (defaults to now)
            
        Returns:
            Updated user profile
        """
        now = timestamp or datetime.now()
        
        # Get or create profile
        if user_id not in self._user_profiles:
            self._user_profiles[user_id] = UserProfile(
                user_id=user_id,
                first_seen_at=now,
            )
            self._query_history[user_id] = []
        
        profile = self._user_profiles[user_id]
        
        # Update query tracking
        profile.query_count_total += 1
        profile.last_query_at = now
        self._query_history[user_id].append(now)
        
        # Prune old history (keep only 30 days)
        cutoff = now - timedelta(days=30)
        self._query_history[user_id] = [
            ts for ts in self._query_history[user_id] if ts > cutoff
        ]
        
        # Update 7-day counts
        week_cutoff = now - timedelta(days=7)
        profile.query_count_7d = len([
            ts for ts in self._query_history[user_id] if ts > week_cutoff
        ])
        profile.avg_daily_queries = profile.query_count_7d / 7.0
        
        # Reclassify segment
        profile.segment = self._classify_segment(profile, now)
        profile.sample_rate = self.config.sampling_rates[profile.segment]
        
        return profile
    
    def _classify_segment(self, profile: UserProfile, now: datetime) -> str:
        """
        Classify user into a population segment.
        
        Args:
            profile: User profile with query statistics
            now: Current timestamp
            
        Returns:
            Segment name: power_user, regular_user, occasional_user, new_user
        """
        # Check if new user (first 30 days)
        if profile.first_seen_at:
            days_since_first = (now - profile.first_seen_at).days
            if days_since_first < self.config.new_user_window_days:
                return "new_user"
        
        # Classify by query volume
        if profile.avg_daily_queries > self.config.power_user_threshold:
            return "power_user"
        elif profile.avg_daily_queries >= self.config.regular_user_min:
            return "regular_user"
        else:
            return "occasional_user"
    
    def should_sample(self, user_id: str) -> bool:
        """
        Determine if a query from this user should be sampled for drift analysis.
        
        Uses probabilistic sampling based on user segment.
        
        Args:
            user_id: User identifier
            
        Returns:
            True if query should be sampled, False otherwise
        """
        profile = self._user_profiles.get(user_id)
        
        if profile is None:
            # Unknown user - sample at regular rate
            return random.random() < self.config.sampling_rates["regular_user"]
        
        return random.random() < profile.sample_rate
    
    def get_user_segment(self, user_id: str) -> str:
        """
        Get the current segment classification for a user.
        
        Args:
            user_id: User identifier
            
        Returns:
            Segment name or "unknown" if not yet classified
        """
        profile = self._user_profiles.get(user_id)
        return profile.segment if profile else "unknown"
    
    def get_user_profile(self, user_id: str) -> Optional[UserProfile]:
        """
        Get the full profile for a user.
        
        Args:
            user_id: User identifier
            
        Returns:
            UserProfile if exists, None otherwise
        """
        return self._user_profiles.get(user_id)
    
    def get_focus_metrics(self, user_id: str) -> list[str]:
        """
        Get the focus metrics for drift evaluation based on user segment.
        
        Different user segments have different focus metrics:
        - Power users: All 12 metrics
        - Regular users: TTS-M05, M06, M09, M10
        - Occasional users: TTS-M09, M10 only
        - New users: TTS-M06, M08 (ambiguity focus)
        
        Args:
            user_id: User identifier
            
        Returns:
            List of metric codes to evaluate
        """
        segment = self.get_user_segment(user_id)
        return self.config.focus_metrics.get(segment, self.config.focus_metrics["regular_user"])
    
    def get_sampling_frequency(self, user_id: str) -> str:
        """
        Get the sampling frequency for a user's segment.
        
        Args:
            user_id: User identifier
            
        Returns:
            Frequency: "realtime", "hourly", or "daily"
        """
        segment = self.get_user_segment(user_id)
        return self.config.sampling_frequency.get(segment, "hourly")
    
    def get_segment_statistics(self) -> dict[str, dict[str, Any]]:
        """
        Get statistics for all user segments.
        
        Returns:
            Dictionary with segment statistics
        """
        stats: dict[str, dict[str, Any]] = {
            "power_user": {"count": 0, "total_queries": 0, "avg_daily": 0.0},
            "regular_user": {"count": 0, "total_queries": 0, "avg_daily": 0.0},
            "occasional_user": {"count": 0, "total_queries": 0, "avg_daily": 0.0},
            "new_user": {"count": 0, "total_queries": 0, "avg_daily": 0.0},
        }
        
        for profile in self._user_profiles.values():
            if profile.segment in stats:
                stats[profile.segment]["count"] += 1
                stats[profile.segment]["total_queries"] += profile.query_count_total
        
        # Compute averages
        for segment in stats:
            if stats[segment]["count"] > 0:
                stats[segment]["avg_daily"] = (
                    stats[segment]["total_queries"] / (stats[segment]["count"] * 7)
                )
        
        return stats
    
    def export_profiles(self) -> list[dict[str, Any]]:
        """
        Export all user profiles as dictionaries.
        
        Returns:
            List of user profile dictionaries
        """
        return [profile.to_dict() for profile in self._user_profiles.values()]
    
    def import_profiles(self, profiles: list[dict[str, Any]]) -> int:
        """
        Import user profiles from dictionaries.
        
        Args:
            profiles: List of profile dictionaries
            
        Returns:
            Number of profiles imported
        """
        count = 0
        for data in profiles:
            try:
                profile = UserProfile(
                    user_id=data["user_id"],
                    segment=data.get("segment", "unknown"),
                    first_seen_at=datetime.fromisoformat(data["first_seen_at"]) if data.get("first_seen_at") else None,
                    last_query_at=datetime.fromisoformat(data["last_query_at"]) if data.get("last_query_at") else None,
                    query_count_total=data.get("query_count_total", 0),
                    query_count_7d=data.get("query_count_7d", 0),
                    avg_daily_queries=data.get("avg_daily_queries", 0.0),
                    sample_rate=data.get("sample_rate", 0.2),
                )
                self._user_profiles[profile.user_id] = profile
                self._query_history[profile.user_id] = []  # History not exported
                count += 1
            except (KeyError, ValueError):
                continue
        
        return count


class BatchSampler:
    """
    Batch sampler for offline drift evaluation.
    
    This class supports the batch evaluation modes described in Chapter 18:
    - Training Data Generation: 500 queries, per batch
    - CI/CD Gate: 100 queries × 3 repetitions, per PR
    - Production Monitoring: 1000 queries, daily
    """
    
    def __init__(self, population_sampler: UserPopulationSampler):
        """
        Initialize the batch sampler.
        
        Args:
            population_sampler: User population sampler for segment-aware sampling
        """
        self.population_sampler = population_sampler
    
    def sample_for_training(
        self,
        queries: list[dict[str, Any]],
        target_size: int = 500,
    ) -> list[dict[str, Any]]:
        """
        Sample queries for training data generation evaluation.
        
        Args:
            queries: List of query records
            target_size: Target sample size (default 500)
            
        Returns:
            Sampled queries
        """
        return self._stratified_sample(queries, target_size)
    
    def sample_for_ci_cd(
        self,
        queries: list[dict[str, Any]],
        target_size: int = 100,
        repetitions: int = 3,
    ) -> list[list[dict[str, Any]]]:
        """
        Sample queries for CI/CD gate evaluation.
        
        Args:
            queries: List of query records
            target_size: Target sample size per repetition
            repetitions: Number of repetitions
            
        Returns:
            List of sampled query batches
        """
        batches = []
        for _ in range(repetitions):
            batch = self._stratified_sample(queries, target_size)
            batches.append(batch)
        return batches
    
    def sample_for_production(
        self,
        queries: list[dict[str, Any]],
        target_size: int = 1000,
    ) -> list[dict[str, Any]]:
        """
        Sample queries for daily production monitoring.
        
        Args:
            queries: List of query records
            target_size: Target sample size (default 1000)
            
        Returns:
            Sampled queries
        """
        return self._stratified_sample(queries, target_size)
    
    def _stratified_sample(
        self,
        queries: list[dict[str, Any]],
        target_size: int,
    ) -> list[dict[str, Any]]:
        """
        Perform stratified sampling based on user segments.
        
        Ensures representation from all user segments proportional to
        their sampling rates.
        """
        if len(queries) <= target_size:
            return queries
        
        # Group by segment
        by_segment: dict[str, list[dict[str, Any]]] = {
            "power_user": [],
            "regular_user": [],
            "occasional_user": [],
            "new_user": [],
            "unknown": [],
        }
        
        for query in queries:
            user_id = query.get("user_id", "")
            segment = self.population_sampler.get_user_segment(user_id)
            if segment not in by_segment:
                segment = "unknown"
            by_segment[segment].append(query)
        
        # Sample from each segment
        sampled = []
        total_rate = sum(
            self.population_sampler.config.sampling_rates.get(seg, 0.2) * len(by_segment[seg])
            for seg in by_segment
        )
        
        for segment, segment_queries in by_segment.items():
            if not segment_queries:
                continue
            
            rate = self.population_sampler.config.sampling_rates.get(segment, 0.2)
            segment_target = int(target_size * (rate * len(segment_queries)) / max(total_rate, 1))
            segment_target = min(segment_target, len(segment_queries))
            
            if segment_target > 0:
                sampled.extend(random.sample(segment_queries, segment_target))
        
        # Fill remaining slots randomly if needed
        remaining = target_size - len(sampled)
        if remaining > 0:
            unsampled = [q for q in queries if q not in sampled]
            if unsampled:
                sampled.extend(random.sample(unsampled, min(remaining, len(unsampled))))
        
        return sampled[:target_size]


# =============================================================================
# CLI Entry Point
# =============================================================================

def main():
    """CLI entry point for user population sampling."""
    import argparse
    import json
    
    parser = argparse.ArgumentParser(
        description="Text-to-SQL User Population Sampler",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--action",
        choices=["stats", "classify", "sample"],
        default="stats",
        help="Action to perform",
    )
    parser.add_argument(
        "--profiles",
        help="Path to user profiles JSON file",
    )
    parser.add_argument(
        "--queries",
        help="Path to queries JSONL file (for sample action)",
    )
    parser.add_argument(
        "--target-size",
        type=int,
        default=500,
        help="Target sample size",
    )
    parser.add_argument(
        "--output",
        default="sampled_queries.json",
        help="Output path for sampled queries",
    )
    
    args = parser.parse_args()
    
    # Create sampler
    sampler = UserPopulationSampler()
    
    if args.action == "stats":
        print("User Population Sampling Configuration:")
        print(f"  Power User threshold: >{sampler.config.power_user_threshold} queries/day")
        print(f"  Regular User range: {sampler.config.regular_user_min}-{sampler.config.power_user_threshold} queries/day")
        print(f"  New User window: {sampler.config.new_user_window_days} days")
        print("\nSampling Rates:")
        for segment, rate in sampler.config.sampling_rates.items():
            print(f"  {segment}: {rate*100:.0f}%")
    
    elif args.action == "classify":
        print("Would classify users from profiles...")
        print("\nNote: This is a stub implementation. Full implementation pending.")
    
    elif args.action == "sample":
        print(f"Would sample {args.target_size} queries...")
        print("\nNote: This is a stub implementation. Full implementation pending.")
    
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())