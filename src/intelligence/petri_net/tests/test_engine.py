"""Tests for CPN execution engine."""

import asyncio
import pytest

from petri_net.core import TokenColour, Place, Transition, Arc, ArcDirection, PetriNet
from petri_net.engine import CPNEngine


def _simple_net():
    """p1 --[t1]--> p2"""
    net = PetriNet(name="simple")
    p1 = net.add_place(Place(name="p1"))
    p2 = net.add_place(Place(name="p2"))
    t1 = net.add_transition(Transition(name="t1"))
    net.add_arc(Arc(place=p1, transition=t1, direction=ArcDirection.INPUT, variable="x"))
    net.add_arc(Arc(
        place=p2, transition=t1, direction=ArcDirection.OUTPUT,
        expression=lambda b: [TokenColour(data="produced", colour="default")],
    ))
    p1.add_token(TokenColour(data="input", colour="default"))
    return net


class TestFiring:
    def test_enabled_transitions(self):
        net = _simple_net()
        engine = CPNEngine(net)
        enabled = engine.enabled_transitions()
        assert len(enabled) == 1
        assert enabled[0][0].name == "t1"

    def test_fire(self):
        net = _simple_net()
        engine = CPNEngine(net)
        enabled = engine.enabled_transitions()
        t, binding = enabled[0]
        engine.fire(t, binding)
        assert net.place_by_name("p1").is_empty()
        assert net.place_by_name("p2").token_count == 1

    def test_step(self):
        net = _simple_net()
        engine = CPNEngine(net)
        result = engine.step()
        assert result is not None
        assert result[0] == "t1"
        # No more enabled
        assert engine.step() is None

    def test_run(self):
        net = _simple_net()
        engine = CPNEngine(net)
        steps = engine.run()
        assert steps == 1
        assert engine.step_count == 1

    def test_run_max_steps(self):
        net = _simple_net()
        # Add more tokens
        net.place_by_name("p1").add_token(TokenColour(data="input2"))
        net.place_by_name("p1").add_token(TokenColour(data="input3"))
        engine = CPNEngine(net)
        steps = engine.run(max_steps=2)
        assert steps == 2


class TestGuard:
    def test_guard_blocks(self):
        net = PetriNet(name="guarded")
        p1 = net.add_place(Place(name="p1"))
        p2 = net.add_place(Place(name="p2"))
        t = net.add_transition(Transition(
            name="t1",
            guard=lambda b: b.get("x") and b["x"].data > 10,
        ))
        net.add_arc(Arc(place=p1, transition=t, direction=ArcDirection.INPUT, variable="x"))
        net.add_arc(Arc(place=p2, transition=t, direction=ArcDirection.OUTPUT,
                        expression=lambda b: [TokenColour(data="ok")]))
        # Token with data=5 won't pass guard
        p1.add_token(TokenColour(data=5))
        engine = CPNEngine(net)
        assert len(engine.enabled_transitions()) == 0

        # Token with data=20 passes
        p1.add_token(TokenColour(data=20))
        enabled = engine.enabled_transitions()
        assert len(enabled) >= 1


class TestInhibitor:
    def test_inhibitor_blocks_when_place_has_tokens(self):
        net = PetriNet(name="inhibitor_test")
        p_in = net.add_place(Place(name="input"))
        p_block = net.add_place(Place(name="blocker"))
        p_out = net.add_place(Place(name="output"))
        t = net.add_transition(Transition(name="t1"))
        net.add_arc(Arc(place=p_in, transition=t, direction=ArcDirection.INPUT, variable="x"))
        net.add_arc(Arc(place=p_block, transition=t, direction=ArcDirection.INHIBITOR, weight=0))
        net.add_arc(Arc(place=p_out, transition=t, direction=ArcDirection.OUTPUT,
                        expression=lambda b: [TokenColour(data="done")]))
        p_in.add_token(TokenColour(data="go"))
        # blocker has token → inhibitor blocks
        p_block.add_token(TokenColour(data="block"))
        engine = CPNEngine(net)
        assert len(engine.enabled_transitions()) == 0
        # Remove blocker
        p_block.remove_token(TokenColour(data="block"))
        assert len(engine.enabled_transitions()) == 1


class TestPriority:
    def test_higher_priority_fires_first(self):
        net = PetriNet(name="priority_test")
        p = net.add_place(Place(name="p1"))
        p_out1 = net.add_place(Place(name="out1"))
        p_out2 = net.add_place(Place(name="out2"))
        t_low = net.add_transition(Transition(name="low", priority=1))
        t_high = net.add_transition(Transition(name="high", priority=10))
        net.add_arc(Arc(place=p, transition=t_low, direction=ArcDirection.INPUT, variable="x"))
        net.add_arc(Arc(place=p_out1, transition=t_low, direction=ArcDirection.OUTPUT,
                        expression=lambda b: [TokenColour(data="low")]))
        net.add_arc(Arc(place=p, transition=t_high, direction=ArcDirection.INPUT, variable="x"))
        net.add_arc(Arc(place=p_out2, transition=t_high, direction=ArcDirection.OUTPUT,
                        expression=lambda b: [TokenColour(data="high")]))
        p.add_token(TokenColour(data="token"))
        engine = CPNEngine(net)
        result = engine.step()
        assert result[0] == "high"


class TestDeadlock:
    def test_deadlock_detection(self):
        """Deadlock: token stuck in p1 (non-terminal) but t1 needs p1 AND p_other."""
        net = PetriNet(name="deadlock")
        p1 = net.add_place(Place(name="p1"))
        p_other = net.add_place(Place(name="p_other"))
        p_out = net.add_place(Place(name="p_out"))
        t = net.add_transition(Transition(name="t1"))
        net.add_arc(Arc(place=p1, transition=t, direction=ArcDirection.INPUT, variable="x"))
        net.add_arc(Arc(place=p_other, transition=t, direction=ArcDirection.INPUT, variable="y"))
        net.add_arc(Arc(place=p_out, transition=t, direction=ArcDirection.OUTPUT,
                        expression=lambda b: [TokenColour(data="ok")]))
        # Token in p1 but not p_other → t1 can't fire → deadlocked
        p1.add_token(TokenColour(data="stuck"))
        engine = CPNEngine(net)
        assert engine.is_deadlocked()
        info = engine.detect_deadlock()
        assert info["deadlocked"]
        assert "p1" in info["non_empty_places"]

    def test_no_deadlock_when_empty(self):
        net = PetriNet(name="clean")
        p1 = net.add_place(Place(name="p1"))
        t = net.add_transition(Transition(name="t1"))
        net.add_arc(Arc(place=p1, transition=t, direction=ArcDirection.INPUT, variable="x"))
        engine = CPNEngine(net)
        assert not engine.is_deadlocked()

    def test_no_deadlock_when_tokens_in_terminal(self):
        """Tokens only in terminal places (no outgoing arcs) → not a deadlock."""
        net = PetriNet(name="clean_terminal")
        p1 = net.add_place(Place(name="p1"))
        p_end = net.add_place(Place(name="p_end"))
        t = net.add_transition(Transition(name="t1"))
        net.add_arc(Arc(place=p1, transition=t, direction=ArcDirection.INPUT, variable="x"))
        net.add_arc(Arc(place=p_end, transition=t, direction=ArcDirection.OUTPUT,
                        expression=lambda b: [TokenColour(data="done")]))
        p_end.add_token(TokenColour(data="result"))
        engine = CPNEngine(net)
        assert not engine.is_deadlocked()


class TestConcurrent:
    def test_run_async(self):
        net = _simple_net()
        net.place_by_name("p1").add_token(TokenColour(data="input2"))
        engine = CPNEngine(net)
        steps = asyncio.run(engine.run_async())
        # Both should have fired (no conflict since single input place - sequential)
        assert steps >= 1


class TestLiveness:
    def test_dead_transitions(self):
        net = PetriNet(name="liveness")
        p1 = net.add_place(Place(name="p1"))
        p2 = net.add_place(Place(name="p2"))
        t1 = net.add_transition(Transition(name="can_fire"))
        t2 = net.add_transition(Transition(name="cannot_fire"))
        net.add_arc(Arc(place=p1, transition=t1, direction=ArcDirection.INPUT, variable="x"))
        net.add_arc(Arc(place=p2, transition=t1, direction=ArcDirection.OUTPUT,
                        expression=lambda b: [TokenColour(data="ok")]))
        net.add_arc(Arc(place=p2, transition=t2, direction=ArcDirection.INPUT, variable="y"))
        p1.add_token(TokenColour(data="go"))
        engine = CPNEngine(net)
        dead = engine.dead_transitions()
        assert "cannot_fire" in dead
        assert "can_fire" not in dead
