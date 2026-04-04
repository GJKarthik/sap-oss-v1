"""State persistence for CPN engine: save, load, checkpoint."""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from .core import Arc, ArcDirection, PetriNet, Place, TokenColour, Transition


def _serialize_token(token: TokenColour) -> Dict[str, Any]:
    return {"data": token.data, "colour": token.colour}


def _deserialize_token(d: Dict[str, Any]) -> TokenColour:
    return TokenColour(data=d["data"], colour=d["colour"])


def _serialize_marking(net: PetriNet) -> Dict[str, Any]:
    """Serialize current marking (tokens in each place)."""
    marking = {}
    for p in net.places.values():
        marking[p.name] = [_serialize_token(t) for t in p.tokens]
    return marking


def _serialize_net_structure(net: PetriNet) -> Dict[str, Any]:
    """Serialize net topology (places, transitions, arcs) — without callables."""
    places = []
    for p in net.places.values():
        places.append({
            "id": p.id,
            "name": p.name,
            "capacity": p.capacity,
            "accepted_colours": p.accepted_colours,
        })
    transitions = []
    for t in net.transitions.values():
        transitions.append({
            "id": t.id,
            "name": t.name,
            "priority": t.priority,
            "delay": t.delay,
            "has_guard": t.guard is not None,
            "has_action": t.action is not None,
        })
    arcs = []
    for a in net.arcs:
        arcs.append({
            "place_name": a.place.name,
            "transition_name": a.transition.name,
            "direction": a.direction.value,
            "weight": a.weight,
            "variable": a.variable,
            "has_expression": a.expression is not None,
        })
    return {
        "name": net.name,
        "places": places,
        "transitions": transitions,
        "arcs": arcs,
    }


def save_state(engine: "CPNEngine", path: str) -> None:
    """Serialize entire CPN state (marking + net structure) to JSON."""
    from .engine import CPNEngine

    state = {
        "version": 1,
        "timestamp": time.time(),
        "net": _serialize_net_structure(engine.net),
        "marking": _serialize_marking(engine.net),
        "step_count": engine.step_count,
    }
    path_obj = Path(path)
    path_obj.parent.mkdir(parents=True, exist_ok=True)
    with open(path_obj, "w") as f:
        json.dump(state, f, indent=2, default=str)


def load_state(
    path: str,
    net_factory: Optional[Callable[[], PetriNet]] = None,
) -> "CPNEngine":
    """Restore engine from saved state.

    If net_factory is provided, it rebuilds the net (preserving guards/actions)
    and restores only the marking from the saved state.
    Otherwise, builds a skeleton net from the JSON (without callables).
    """
    from .engine import CPNEngine

    with open(path, "r") as f:
        state = json.load(f)

    if net_factory:
        net = net_factory()
    else:
        net = _rebuild_net_from_json(state["net"])

    # Restore marking
    for place_name, tokens_data in state["marking"].items():
        try:
            place = net.place_by_name(place_name)
        except KeyError:
            continue
        # Clear existing tokens
        place._tokens.clear()
        for td in tokens_data:
            place.add_token(_deserialize_token(td))

    engine = CPNEngine(net)
    engine._step_count = state.get("step_count", 0)
    return engine


def _rebuild_net_from_json(net_data: Dict[str, Any]) -> PetriNet:
    """Rebuild a net from JSON structure (no guards/actions)."""
    net = PetriNet(name=net_data["name"])
    place_map: Dict[str, Place] = {}
    for pd in net_data["places"]:
        p = Place(
            name=pd["name"],
            capacity=pd.get("capacity"),
            accepted_colours=pd.get("accepted_colours"),
        )
        p.id = pd["id"]
        net.add_place(p)
        place_map[pd["name"]] = p

    trans_map: Dict[str, Transition] = {}
    for td in net_data["transitions"]:
        t = Transition(
            name=td["name"],
            priority=td.get("priority", 0),
            delay=td.get("delay"),
        )
        t.id = td["id"]
        net.add_transition(t)
        trans_map[td["name"]] = t

    for ad in net_data["arcs"]:
        arc = Arc(
            place=place_map[ad["place_name"]],
            transition=trans_map[ad["transition_name"]],
            direction=ArcDirection(ad["direction"]),
            weight=ad.get("weight", 1),
            variable=ad.get("variable"),
        )
        net.add_arc(arc)

    return net


def checkpoint(engine: "CPNEngine", directory: str = ".cpn_checkpoints") -> str:
    """Periodic auto-save. Returns the checkpoint file path."""
    path = os.path.join(
        directory, f"checkpoint_{int(time.time())}_{engine.step_count}.json"
    )
    save_state(engine, path)
    return path
