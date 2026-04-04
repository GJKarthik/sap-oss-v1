"""Tests for CPN core model: Place, Transition, Arc, PetriNet."""

import pytest

from petri_net.core import TokenColour, Place, Transition, Arc, ArcDirection, PetriNet


class TestTokenColour:
    def test_creation(self):
        t = TokenColour(data="hello", colour="str")
        assert t.data == "hello"
        assert t.colour == "str"

    def test_default_colour(self):
        t = TokenColour(data=42)
        assert t.colour == "default"

    def test_dict_data(self):
        t = TokenColour(data={"key": "value"}, colour="dict")
        assert t.data["key"] == "value"

    def test_equality(self):
        t1 = TokenColour(data="x", colour="a")
        t2 = TokenColour(data="x", colour="a")
        assert t1 == t2

    def test_hash(self):
        t1 = TokenColour(data=[1, 2], colour="list")
        t2 = TokenColour(data=[1, 2], colour="list")
        assert hash(t1) == hash(t2)


class TestPlace:
    def test_add_remove_token(self):
        p = Place(name="p1")
        t = TokenColour(data="x")
        p.add_token(t)
        assert p.token_count == 1
        p.remove_token(t)
        assert p.is_empty()

    def test_capacity(self):
        p = Place(name="p1", capacity=1)
        p.add_token(TokenColour(data="x"))
        with pytest.raises(OverflowError):
            p.add_token(TokenColour(data="y"))

    def test_accepted_colours(self):
        p = Place(name="p1", accepted_colours=["red"])
        p.add_token(TokenColour(data="ok", colour="red"))
        with pytest.raises(ValueError, match="does not accept"):
            p.add_token(TokenColour(data="bad", colour="blue"))

    def test_remove_missing_token(self):
        p = Place(name="p1")
        with pytest.raises(ValueError, match="not found"):
            p.remove_token(TokenColour(data="nope"))


class TestArc:
    def test_arc_weight_validation(self):
        p = Place(name="p1")
        t = Transition(name="t1")
        with pytest.raises(ValueError):
            Arc(place=p, transition=t, direction=ArcDirection.INPUT, weight=0)

    def test_inhibitor_zero_weight(self):
        p = Place(name="p1")
        t = Transition(name="t1")
        arc = Arc(place=p, transition=t, direction=ArcDirection.INHIBITOR, weight=0)
        assert arc.direction == ArcDirection.INHIBITOR


class TestPetriNet:
    def test_add_place_transition(self):
        net = PetriNet(name="test")
        p = net.add_place(Place(name="p1"))
        t = net.add_transition(Transition(name="t1"))
        assert len(net.places) == 1
        assert len(net.transitions) == 1

    def test_add_arc_validates(self):
        net = PetriNet(name="test")
        p = Place(name="p1")
        t = Transition(name="t1")
        net.add_place(p)
        # Transition not in net
        with pytest.raises(ValueError, match="not in net"):
            net.add_arc(Arc(place=p, transition=t, direction=ArcDirection.INPUT))

    def test_place_by_name(self):
        net = PetriNet(name="test")
        p = net.add_place(Place(name="my_place"))
        assert net.place_by_name("my_place") is p
        with pytest.raises(KeyError):
            net.place_by_name("nonexistent")

    def test_validate_empty(self):
        net = PetriNet()
        issues = net.validate()
        assert "Net has no places" in issues

    def test_validate_disconnected_transition(self):
        net = PetriNet()
        net.add_place(Place(name="p1"))
        net.add_transition(Transition(name="t1"))
        issues = net.validate()
        assert any("has no arcs" in i for i in issues)

    def test_input_output_arcs(self):
        net = PetriNet()
        p1 = net.add_place(Place(name="p1"))
        p2 = net.add_place(Place(name="p2"))
        t = net.add_transition(Transition(name="t1"))
        a_in = net.add_arc(Arc(place=p1, transition=t, direction=ArcDirection.INPUT))
        a_out = net.add_arc(Arc(place=p2, transition=t, direction=ArcDirection.OUTPUT))
        assert len(net.input_arcs(t)) == 1
        assert len(net.output_arcs(t)) == 1
