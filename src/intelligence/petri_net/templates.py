"""Pre-built workflow templates as Coloured Petri Nets."""

from __future__ import annotations

from typing import Any, Dict, List

from .core import Arc, ArcDirection, PetriNet, Place, TokenColour, Transition


def _simple_arc_expr(binding: Dict[str, Any]) -> List[TokenColour]:
    """Default output arc expression: produce one default token."""
    return [TokenColour(data="done", colour="default")]


def _make_sequential_stage(
    net: PetriNet,
    pre_place: Place,
    stage_name: str,
    post_place: Place | None = None,
    priority: int = 0,
) -> Place:
    """Wire a simple Place→Transition→Place stage. Returns the output place."""
    t = net.add_transition(Transition(name=stage_name, priority=priority))
    if post_place is None:
        post_place = net.add_place(Place(name=f"after_{stage_name}"))
    net.add_arc(Arc(
        place=pre_place, transition=t, direction=ArcDirection.INPUT,
        variable=pre_place.name,
    ))
    net.add_arc(Arc(
        place=post_place, transition=t, direction=ArcDirection.OUTPUT,
        expression=_simple_arc_expr,
    ))
    return post_place


# ---------------------------------------------------------------------------
# Training pipeline
# ---------------------------------------------------------------------------

def training_pipeline_net() -> PetriNet:
    """CPN modelling 8-stage training pipeline with fork-join parallelism.

    Stage 1 (Preconvert) → fork:
        Stage 2 (Build)           ┐
        Stage 3 (Extract Schema)  ├→ Stage 5 (Expand) → fork:
        Stage 4 (Parse Templates) ┘      Stage 6 (Generate) → Stage 7 (Validate)
                                          Stage 8 (Arabic)  ─────────────────────→ done
    """
    net = PetriNet(name="training_pipeline")

    # -- Places --
    start = net.add_place(Place(name="start"))
    start.add_token(TokenColour(data="pipeline_input", colour="default"))

    after_preconvert = net.add_place(Place(name="after_preconvert"))
    # Fork outputs
    ready_build = net.add_place(Place(name="ready_build"))
    ready_schema = net.add_place(Place(name="ready_schema"))
    ready_parse = net.add_place(Place(name="ready_parse"))
    # After parallel stages
    done_build = net.add_place(Place(name="done_build"))
    done_schema = net.add_place(Place(name="done_schema"))
    done_parse = net.add_place(Place(name="done_parse"))
    # Join
    after_expand = net.add_place(Place(name="after_expand"))
    # Second fork
    ready_gen = net.add_place(Place(name="ready_gen"))
    ready_arabic = net.add_place(Place(name="ready_arabic"))
    after_gen = net.add_place(Place(name="after_gen"))
    after_validate = net.add_place(Place(name="after_validate"))
    after_arabic = net.add_place(Place(name="after_arabic"))
    done = net.add_place(Place(name="done"))

    # -- Stage 1: Preconvert --
    _make_sequential_stage(net, start, "preconvert", after_preconvert)

    # -- Fork after preconvert → 3 parallel paths --
    t_fork1 = net.add_transition(Transition(name="fork_after_preconvert"))
    net.add_arc(Arc(place=after_preconvert, transition=t_fork1,
                    direction=ArcDirection.INPUT, variable="after_preconvert"))
    for p in [ready_build, ready_schema, ready_parse]:
        net.add_arc(Arc(place=p, transition=t_fork1,
                        direction=ArcDirection.OUTPUT, expression=_simple_arc_expr))

    # -- Stage 2, 3, 4 (parallel) --
    _make_sequential_stage(net, ready_build, "build", done_build)
    _make_sequential_stage(net, ready_schema, "extract_schema", done_schema)
    _make_sequential_stage(net, ready_parse, "parse_templates", done_parse)

    # -- Join: Stage 5 (Expand) waits for 2+3+4 --
    t_expand = net.add_transition(Transition(name="expand"))
    for p in [done_build, done_schema, done_parse]:
        net.add_arc(Arc(place=p, transition=t_expand,
                        direction=ArcDirection.INPUT, variable=p.name))
    net.add_arc(Arc(place=after_expand, transition=t_expand,
                    direction=ArcDirection.OUTPUT, expression=_simple_arc_expr))

    # -- Fork after expand → gen path + arabic --
    t_fork2 = net.add_transition(Transition(name="fork_after_expand"))
    net.add_arc(Arc(place=after_expand, transition=t_fork2,
                    direction=ArcDirection.INPUT, variable="after_expand"))
    for p in [ready_gen, ready_arabic]:
        net.add_arc(Arc(place=p, transition=t_fork2,
                        direction=ArcDirection.OUTPUT, expression=_simple_arc_expr))

    # -- Stage 6: Generate, Stage 7: Validate (sequential) --
    _make_sequential_stage(net, ready_gen, "generate", after_gen)
    _make_sequential_stage(net, after_gen, "validate", after_validate)

    # -- Stage 8: Arabic (parallel with 6-7) --
    _make_sequential_stage(net, ready_arabic, "arabic", after_arabic)

    # -- Join to done --
    t_done = net.add_transition(Transition(name="join_done"))
    for p in [after_validate, after_arabic]:
        net.add_arc(Arc(place=p, transition=t_done,
                        direction=ArcDirection.INPUT, variable=p.name))
    net.add_arc(Arc(place=done, transition=t_done,
                    direction=ArcDirection.OUTPUT, expression=_simple_arc_expr))

    return net


# ---------------------------------------------------------------------------
# OCR batch processing
# ---------------------------------------------------------------------------

def ocr_batch_net(n_documents: int = 5) -> PetriNet:
    """CPN for parallel OCR processing with configurable concurrency.

    Pattern: pool of worker slots controls max parallelism.
    Documents flow: queue → processing (limited slots) → done.
    """
    net = PetriNet(name="ocr_batch")

    queue = net.add_place(Place(name="queue"))
    processing = net.add_place(Place(name="processing"))
    done_place = net.add_place(Place(name="done"))
    # Concurrency limiter: 3 worker slots
    slots = net.add_place(Place(name="worker_slots"))
    for i in range(3):
        slots.add_token(TokenColour(data=f"slot_{i}", colour="slot"))

    # Add documents to queue
    for i in range(n_documents):
        queue.add_token(TokenColour(data={"doc_id": i, "filename": f"doc_{i}.pdf"}, colour="document"))

    # Transition: start_ocr (takes a doc + a slot → processing)
    t_start = net.add_transition(Transition(name="start_ocr"))
    net.add_arc(Arc(place=queue, transition=t_start,
                    direction=ArcDirection.INPUT, variable="doc"))
    net.add_arc(Arc(place=slots, transition=t_start,
                    direction=ArcDirection.INPUT, variable="slot"))
    net.add_arc(Arc(
        place=processing, transition=t_start,
        direction=ArcDirection.OUTPUT,
        expression=lambda b: [TokenColour(
            data={"doc": b["doc"].data, "slot": b["slot"].data},
            colour="processing",
        )],
    ))

    # Transition: finish_ocr (processing → done + return slot)
    t_finish = net.add_transition(Transition(name="finish_ocr"))
    net.add_arc(Arc(place=processing, transition=t_finish,
                    direction=ArcDirection.INPUT, variable="job"))
    net.add_arc(Arc(
        place=done_place, transition=t_finish,
        direction=ArcDirection.OUTPUT,
        expression=lambda b: [TokenColour(
            data={"doc": b["job"].data["doc"], "result": "ocr_complete"},
            colour="result",
        )],
    ))
    net.add_arc(Arc(
        place=slots, transition=t_finish,
        direction=ArcDirection.OUTPUT,
        expression=lambda b: [TokenColour(
            data=b["job"].data["slot"], colour="slot",
        )],
    ))

    return net


# ---------------------------------------------------------------------------
# Model deployment pipeline
# ---------------------------------------------------------------------------

def model_deploy_net() -> PetriNet:
    """CPN for export → deploy → health check → smoke test → promote."""
    net = PetriNet(name="model_deploy")

    start = net.add_place(Place(name="start"))
    start.add_token(TokenColour(data="model_v1", colour="default"))

    after_export = net.add_place(Place(name="after_export"))
    after_deploy = net.add_place(Place(name="after_deploy"))
    after_health = net.add_place(Place(name="after_health_check"))
    after_smoke = net.add_place(Place(name="after_smoke_test"))
    promoted = net.add_place(Place(name="promoted"))

    _make_sequential_stage(net, start, "export", after_export)
    _make_sequential_stage(net, after_export, "deploy", after_deploy)
    _make_sequential_stage(net, after_deploy, "health_check", after_health)
    _make_sequential_stage(net, after_health, "smoke_test", after_smoke)
    _make_sequential_stage(net, after_smoke, "promote", promoted)

    return net
