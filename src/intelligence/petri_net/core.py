"""Core Coloured Petri Net model: tokens, places, transitions, arcs, and net container."""

from __future__ import annotations

import enum
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Type, Union


# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class TokenColour:
    """A typed token carrying arbitrary structured data."""
    data: Any
    colour: str = "default"  # logical colour / type tag

    def __post_init__(self):
        if self.colour is None:
            object.__setattr__(self, "colour", "default")

    # Convenience: allow hashing even when data is a dict/list by using repr
    def __hash__(self):
        return hash((repr(self.data), self.colour))

    def __eq__(self, other):
        if not isinstance(other, TokenColour):
            return NotImplemented
        return self.data == other.data and self.colour == other.colour


# ---------------------------------------------------------------------------
# Place
# ---------------------------------------------------------------------------

class Place:
    """A place in the CPN holding a multiset of coloured tokens."""

    def __init__(
        self,
        name: str,
        capacity: Optional[int] = None,
        accepted_colours: Optional[List[str]] = None,
    ):
        self.id: str = str(uuid.uuid4())
        self.name = name
        self.capacity = capacity  # None → unlimited
        self.accepted_colours = accepted_colours  # None → accept all
        self._tokens: List[TokenColour] = []

    # -- token operations ---------------------------------------------------

    def add_token(self, token: TokenColour) -> None:
        if self.accepted_colours and token.colour not in self.accepted_colours:
            raise ValueError(
                f"Place '{self.name}' does not accept colour '{token.colour}'. "
                f"Accepted: {self.accepted_colours}"
            )
        if self.capacity is not None and len(self._tokens) >= self.capacity:
            raise OverflowError(
                f"Place '{self.name}' at capacity ({self.capacity})"
            )
        self._tokens.append(token)

    def remove_token(self, token: TokenColour) -> None:
        try:
            self._tokens.remove(token)
        except ValueError:
            raise ValueError(f"Token {token} not found in place '{self.name}'")

    @property
    def tokens(self) -> List[TokenColour]:
        return list(self._tokens)

    @property
    def token_count(self) -> int:
        return len(self._tokens)

    def is_empty(self) -> bool:
        return len(self._tokens) == 0

    def __repr__(self):
        return f"Place('{self.name}', tokens={self.token_count})"


# ---------------------------------------------------------------------------
# Arc
# ---------------------------------------------------------------------------

class ArcDirection(enum.Enum):
    INPUT = "input"        # Place → Transition
    OUTPUT = "output"      # Transition → Place
    INHIBITOR = "inhibitor"  # Place → Transition (fires only if place empty)


@dataclass
class Arc:
    """Connects a Place to a Transition (or vice-versa)."""
    place: Place
    transition: "Transition"
    direction: ArcDirection
    weight: int = 1
    expression: Optional[Callable[[Dict[str, Any]], List[TokenColour]]] = None
    # For input arcs: variable name to bind the consumed token to
    variable: Optional[str] = None

    def __post_init__(self):
        if self.weight < 1 and self.direction != ArcDirection.INHIBITOR:
            raise ValueError("Arc weight must be >= 1")


# ---------------------------------------------------------------------------
# Transition
# ---------------------------------------------------------------------------

class Transition:
    """A transition in the CPN with guard, action, priority, and optional delay."""

    def __init__(
        self,
        name: str,
        guard: Optional[Callable[[Dict[str, Any]], bool]] = None,
        action: Optional[Callable[[Dict[str, Any]], Dict[str, Any]]] = None,
        priority: int = 0,
        delay: Optional[float] = None,
    ):
        self.id: str = str(uuid.uuid4())
        self.name = name
        self.guard = guard        # (binding) -> bool
        self.action = action      # (binding) -> dict  (side-effect)
        self.priority = priority  # higher = fires first
        self.delay = delay        # seconds (for timed transitions)

    def __repr__(self):
        return f"Transition('{self.name}', priority={self.priority})"


# ---------------------------------------------------------------------------
# PetriNet
# ---------------------------------------------------------------------------

class PetriNet:
    """Container for places, transitions, and arcs. Validates on construction."""

    def __init__(self, name: str = "CPN"):
        self.name = name
        self.places: Dict[str, Place] = {}
        self.transitions: Dict[str, Transition] = {}
        self.arcs: List[Arc] = []

    # -- builders -----------------------------------------------------------

    def add_place(self, place: Place) -> Place:
        self.places[place.id] = place
        return place

    def add_transition(self, transition: Transition) -> Transition:
        self.transitions[transition.id] = transition
        return transition

    def add_arc(self, arc: Arc) -> Arc:
        # Validate that place and transition belong to this net
        if arc.place.id not in self.places:
            raise ValueError(f"Place '{arc.place.name}' not in net '{self.name}'")
        if arc.transition.id not in self.transitions:
            raise ValueError(
                f"Transition '{arc.transition.name}' not in net '{self.name}'"
            )
        self.arcs.append(arc)
        return arc

    # -- convenience --------------------------------------------------------

    def input_arcs(self, transition: Transition) -> List[Arc]:
        """Return all input arcs (including inhibitor) for a transition."""
        return [
            a for a in self.arcs
            if a.transition.id == transition.id
            and a.direction in (ArcDirection.INPUT, ArcDirection.INHIBITOR)
        ]

    def output_arcs(self, transition: Transition) -> List[Arc]:
        """Return all output arcs for a transition."""
        return [
            a for a in self.arcs
            if a.transition.id == transition.id
            and a.direction == ArcDirection.OUTPUT
        ]

    def place_by_name(self, name: str) -> Place:
        for p in self.places.values():
            if p.name == name:
                return p
        raise KeyError(f"No place named '{name}'")

    def transition_by_name(self, name: str) -> Transition:
        for t in self.transitions.values():
            if t.name == name:
                return t
        raise KeyError(f"No transition named '{name}'")

    # -- validation ---------------------------------------------------------

    def validate(self) -> List[str]:
        """Return list of structural issues (empty list = valid)."""
        issues: List[str] = []
        if not self.places:
            issues.append("Net has no places")
        if not self.transitions:
            issues.append("Net has no transitions")
        # Every transition should have at least one input or output arc
        for t in self.transitions.values():
            has_arc = any(a.transition.id == t.id for a in self.arcs)
            if not has_arc:
                issues.append(f"Transition '{t.name}' has no arcs")
        return issues

    def __repr__(self):
        return (
            f"PetriNet('{self.name}', "
            f"places={len(self.places)}, "
            f"transitions={len(self.transitions)}, "
            f"arcs={len(self.arcs)})"
        )

    # -- builders -----------------------------------------------------------

    def add_place(self, place: Place) -> Place:
        self.places[place.id] = place
        return place

    def add_transition(self, transition: Transition) -> Transition:
        self.transitions[transition.id] = transition
        return transition
