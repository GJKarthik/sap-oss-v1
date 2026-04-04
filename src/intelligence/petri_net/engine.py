"""CPN execution engine: firing, stepping, deadlock detection, reachability."""

from __future__ import annotations

import asyncio
import random
from collections import defaultdict, deque
from itertools import product
from typing import Any, Dict, FrozenSet, List, Optional, Set, Tuple

from .core import Arc, ArcDirection, PetriNet, Place, TokenColour, Transition


class DeadlockError(Exception):
    """Raised when the net reaches a state with no enabled transitions
    and at least one non-terminal place still holds tokens."""
    pass


class CPNEngine:
    """Execution engine for a Coloured Petri Net."""

    def __init__(self, net: PetriNet):
        self.net = net
        self._step_count = 0
        self._history: List[Tuple[str, Dict[str, Any]]] = []  # (transition_name, binding)

    # ------------------------------------------------------------------
    # Marking
    # ------------------------------------------------------------------

    def marking(self) -> Dict[str, List[TokenColour]]:
        """Current token distribution: place-name → list of tokens."""
        return {p.name: list(p.tokens) for p in self.net.places.values()}

    def marking_snapshot(self) -> FrozenSet[Tuple[str, Tuple]]:
        """Hashable snapshot of the current marking for reachability analysis."""
        items = []
        for p in self.net.places.values():
            toks = tuple(sorted(repr(t) for t in p.tokens))
            items.append((p.name, toks))
        return frozenset(items)

    # ------------------------------------------------------------------
    # Enabled transitions
    # ------------------------------------------------------------------

    def _find_bindings(self, transition: Transition) -> List[Dict[str, Any]]:
        """Find all valid variable bindings for a transition's input arcs."""
        input_arcs = self.net.input_arcs(transition)
        if not input_arcs:
            return [{}]

        # Check inhibitor arcs first
        for arc in input_arcs:
            if arc.direction == ArcDirection.INHIBITOR:
                if not arc.place.is_empty():
                    return []  # inhibitor blocks firing

        # Collect candidate tokens per variable from regular input arcs
        regular_arcs = [a for a in input_arcs if a.direction == ArcDirection.INPUT]
        if not regular_arcs:
            return [{}]

        arc_candidates: List[List[Dict[str, Any]]] = []
        for arc in regular_arcs:
            var = arc.variable or arc.place.name
            tokens = arc.place.tokens
            if len(tokens) < arc.weight:
                return []  # not enough tokens
            candidates = [{ var: t } for t in tokens]
            if not candidates:
                return []
            arc_candidates.append(candidates)

        # Build all combinations
        bindings = []
        for combo in product(*arc_candidates):
            merged: Dict[str, Any] = {}
            for d in combo:
                merged.update(d)
            # Check guard
            if transition.guard and not transition.guard(merged):
                continue
            bindings.append(merged)
        return bindings

    def enabled_transitions(self) -> List[Tuple[Transition, Dict[str, Any]]]:
        """Return list of (transition, binding) pairs that can fire now."""
        enabled = []
        for t in self.net.transitions.values():
            for binding in self._find_bindings(t):
                enabled.append((t, binding))
        # Sort by priority (highest first)
        enabled.sort(key=lambda x: x[0].priority, reverse=True)
        return enabled

    # ------------------------------------------------------------------
    # Firing
    # ------------------------------------------------------------------

    def fire(self, transition: Transition, binding: Dict[str, Any]) -> Dict[str, Any]:
        """Fire a transition with the given binding. Returns action result."""
        # 1. Consume tokens from input arcs
        for arc in self.net.input_arcs(transition):
            if arc.direction == ArcDirection.INHIBITOR:
                continue  # inhibitor arcs don't consume
            if arc.expression:
                tokens_to_consume = arc.expression(binding)
            else:
                var = arc.variable or arc.place.name
                tok = binding.get(var)
                tokens_to_consume = [tok] * arc.weight if tok else []
            for tok in tokens_to_consume:
                arc.place.remove_token(tok)

        # 2. Execute action
        result = {}
        if transition.action:
            result = transition.action(binding) or {}

        # 3. Produce tokens on output arcs
        for arc in self.net.output_arcs(transition):
            if arc.expression:
                tokens_to_produce = arc.expression(binding)
            else:
                # Default: produce a token with the binding data
                tokens_to_produce = [TokenColour(data=binding, colour="default")] * arc.weight
            for tok in tokens_to_produce:
                arc.place.add_token(tok)

        self._step_count += 1
        self._history.append((transition.name, binding))
        return result

    def step(self) -> Optional[Tuple[str, Dict[str, Any]]]:
        """Fire one enabled transition (highest priority, random among equal).
        Returns (transition_name, binding) or None if nothing enabled."""
        enabled = self.enabled_transitions()
        if not enabled:
            return None
        # Group by top priority
        top_priority = enabled[0][0].priority
        top = [e for e in enabled if e[0].priority == top_priority]
        transition, binding = random.choice(top)
        self.fire(transition, binding)
        return (transition.name, binding)

    def run(self, max_steps: Optional[int] = None) -> int:
        """Auto-fire until no transitions enabled or max_steps reached.
        Returns number of steps taken."""
        steps = 0
        while max_steps is None or steps < max_steps:
            result = self.step()
            if result is None:
                break
            steps += 1
        return steps

    async def run_async(self, max_steps: Optional[int] = None) -> int:
        """Fire concurrent-enabled transitions in parallel using asyncio."""
        steps = 0
        while max_steps is None or steps < max_steps:
            enabled = self.enabled_transitions()
            if not enabled:
                break
            # Find non-conflicting transitions (no shared input places)
            to_fire = self._select_concurrent(enabled)
            if not to_fire:
                break

            async def _fire_one(t, b):
                if t.delay:
                    await asyncio.sleep(t.delay)
                return self.fire(t, b)

            await asyncio.gather(*[_fire_one(t, b) for t, b in to_fire])
            steps += len(to_fire)
        return steps

    def _select_concurrent(
        self, enabled: List[Tuple[Transition, Dict[str, Any]]]
    ) -> List[Tuple[Transition, Dict[str, Any]]]:
        """Select non-conflicting transitions that can fire concurrently."""
        selected = []
        used_places: Set[str] = set()
        for t, binding in enabled:
            input_place_ids = {
                a.place.id
                for a in self.net.input_arcs(t)
                if a.direction == ArcDirection.INPUT
            }
            if input_place_ids & used_places:
                continue  # conflict
            selected.append((t, binding))
            used_places |= input_place_ids
        return selected

    # ------------------------------------------------------------------
    # Analysis
    # ------------------------------------------------------------------

    def _terminal_places(self) -> Set[str]:
        """Places that have no outgoing arcs (i.e., are not inputs to any transition)."""
        non_terminal = {
            a.place.id for a in self.net.arcs
            if a.direction in (ArcDirection.INPUT, ArcDirection.INHIBITOR)
        }
        return {p.id for p in self.net.places.values() if p.id not in non_terminal}

    def is_deadlocked(self) -> bool:
        """True if no transitions are enabled but non-terminal places still hold tokens."""
        if self.enabled_transitions():
            return False
        terminal = self._terminal_places()
        # Check if any non-terminal place has tokens
        return any(
            not p.is_empty() for p in self.net.places.values()
            if p.id not in terminal
        )

    def detect_deadlock(self) -> Optional[Dict[str, Any]]:
        """Return deadlock info dict or None if not deadlocked."""
        if not self.is_deadlocked():
            return None
        terminal = self._terminal_places()
        non_empty = {
            p.name: [repr(t) for t in p.tokens]
            for p in self.net.places.values()
            if not p.is_empty() and p.id not in terminal
        }
        return {
            "deadlocked": True,
            "step_count": self._step_count,
            "non_empty_places": non_empty,
        }

    def dead_transitions(self) -> List[str]:
        """Return transitions that can never fire given current marking.
        Simple liveness check: tries all bindings now."""
        dead = []
        for t in self.net.transitions.values():
            if not self._find_bindings(t):
                dead.append(t.name)
        return dead

    def reachability_graph(
        self, max_markings: int = 1000
    ) -> Dict[str, Any]:
        """BFS exploration of reachable markings. Returns graph info.
        Only practical for small nets."""
        import copy
        import json

        initial_net = copy.deepcopy(self.net)
        initial_engine = CPNEngine(initial_net)

        visited: Set = set()
        queue: deque = deque()
        edges: List[Tuple[int, int, str]] = []

        initial_snap = initial_engine.marking_snapshot()
        visited.add(initial_snap)
        marking_list = [initial_snap]
        queue.append((initial_net, 0))

        while queue and len(visited) < max_markings:
            net, idx = queue.popleft()
            eng = CPNEngine(net)
            enabled = eng.enabled_transitions()
            for t, binding in enabled:
                net_copy = copy.deepcopy(net)
                eng_copy = CPNEngine(net_copy)
                t_copy = net_copy.transitions[t.id]
                # rebuild binding with copied tokens
                new_binding = {}
                for k, v in binding.items():
                    if isinstance(v, TokenColour):
                        # find matching token in copied net
                        for p in net_copy.places.values():
                            for tok in p.tokens:
                                if tok == v:
                                    new_binding[k] = tok
                                    break
                    else:
                        new_binding[k] = v
                try:
                    eng_copy.fire(t_copy, new_binding)
                except (ValueError, OverflowError):
                    continue
                snap = eng_copy.marking_snapshot()
                if snap not in visited:
                    visited.add(snap)
                    new_idx = len(marking_list)
                    marking_list.append(snap)
                    edges.append((idx, new_idx, t.name))
                    queue.append((net_copy, new_idx))

        return {
            "markings_explored": len(marking_list),
            "edges": len(edges),
            "edge_list": edges,
        }

    @property
    def step_count(self) -> int:
        return self._step_count

    @property
    def history(self) -> List[Tuple[str, Dict[str, Any]]]:
        return list(self._history)
