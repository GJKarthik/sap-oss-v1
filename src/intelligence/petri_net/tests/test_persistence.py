"""Tests for CPN state persistence."""

import json
import os
import tempfile
import pytest

from petri_net.core import TokenColour, Place, Transition, Arc, ArcDirection, PetriNet
from petri_net.engine import CPNEngine
from petri_net.persistence import save_state, load_state, checkpoint


def _simple_net():
    net = PetriNet(name="persist_test")
    p1 = net.add_place(Place(name="p1"))
    p2 = net.add_place(Place(name="p2"))
    t = net.add_transition(Transition(name="t1"))
    net.add_arc(Arc(place=p1, transition=t, direction=ArcDirection.INPUT, variable="x"))
    net.add_arc(Arc(place=p2, transition=t, direction=ArcDirection.OUTPUT,
                    expression=lambda b: [TokenColour(data="produced")]))
    p1.add_token(TokenColour(data="input_data", colour="default"))
    return net


class TestSaveLoad:
    def test_save_creates_file(self):
        net = _simple_net()
        engine = CPNEngine(net)
        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "state.json")
            save_state(engine, path)
            assert os.path.exists(path)
            with open(path) as f:
                data = json.load(f)
            assert data["version"] == 1
            assert data["net"]["name"] == "persist_test"
            assert len(data["marking"]["p1"]) == 1

    def test_round_trip_without_factory(self):
        net = _simple_net()
        engine = CPNEngine(net)
        engine.fire(*engine.enabled_transitions()[0])

        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "state.json")
            save_state(engine, path)
            restored = load_state(path)
            assert restored.step_count == 1
            m = restored.marking()
            assert len(m["p1"]) == 0
            assert len(m["p2"]) == 1

    def test_round_trip_with_factory(self):
        net = _simple_net()
        engine = CPNEngine(net)
        engine.fire(*engine.enabled_transitions()[0])

        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "state.json")
            save_state(engine, path)
            restored = load_state(path, net_factory=_simple_net)
            # Factory rebuilds net with expressions, marking is restored
            m = restored.marking()
            assert len(m["p1"]) == 0
            assert len(m["p2"]) == 1

    def test_checkpoint(self):
        net = _simple_net()
        engine = CPNEngine(net)
        with tempfile.TemporaryDirectory() as tmpdir:
            cp_path = checkpoint(engine, directory=tmpdir)
            assert os.path.exists(cp_path)
            assert "checkpoint_" in cp_path

    def test_recovery_from_checkpoint(self):
        """Simulate interrupted workflow recovery."""
        net = _simple_net()
        # Add extra tokens for multi-step
        net.place_by_name("p1").add_token(TokenColour(data="second"))
        engine = CPNEngine(net)
        engine.step()  # fire once

        with tempfile.TemporaryDirectory() as tmpdir:
            cp_path = checkpoint(engine, directory=tmpdir)
            # "Server restart" — load from checkpoint with factory
            restored = load_state(cp_path, net_factory=lambda: _simple_net_multi())
            assert restored.step_count == 1
            # Should be able to continue
            m = restored.marking()
            assert len(m["p1"]) == 1  # one token left
            assert len(m["p2"]) == 1  # one consumed


def _simple_net_multi():
    """Same structure as _simple_net but for factory use."""
    net = PetriNet(name="persist_test")
    p1 = net.add_place(Place(name="p1"))
    p2 = net.add_place(Place(name="p2"))
    t = net.add_transition(Transition(name="t1"))
    net.add_arc(Arc(place=p1, transition=t, direction=ArcDirection.INPUT, variable="x"))
    net.add_arc(Arc(place=p2, transition=t, direction=ArcDirection.OUTPUT,
                    expression=lambda b: [TokenColour(data="produced")]))
    return net
