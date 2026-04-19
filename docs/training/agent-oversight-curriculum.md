# Agent-Oversight Training Curriculum

**Status:** ratified v1.0 (April 2026)
**Owner:** Chief Data & AI Office (curriculum), Head of People Operations (delivery)
**Audience:** every employee who reviews, approves, or hands off work to an agentic AI system on SAP OSS infrastructure.
**Closes regulatory requirement:** `REG-MGF-2.4.3-001` (MAS MGF §2.4.3 — equip end users to work responsibly with agentic AI).

## 1 Why this curriculum exists

MAS MGF for Agentic AI §2.4.3 expects organisations to equip the people
on the receiving end of an agent — reviewers, approvers, downstream
consumers — with the understanding they need to work with it
responsibly. Ju & Aral's 2026 field experiment (`REG-JU-ARAL-4-001`)
showed empirically that the failure mode is not catastrophic
breakdown: it is a quiet drop in override rates and review duration
as reviewers defer to the agent. Training is the primary control on
this risk; drift monitoring (`REG-MGF-2.3.3-002`) is the detector.

## 2 Learner personas and required level

| Persona | Required level | Refresh cadence |
| --- | --- | --- |
| **Reviewer** (accepts / rejects agent output) | Level 2 | annually |
| **Approver** (signs off on CFO-bound review packs) | Level 2 + Level 3 oversight module | annually |
| **Downstream consumer** (reads agent-produced summaries) | Level 1 | on role change |
| **Agent owner / product manager** | Level 3 | annually |
| **GFAIC member** (finance-scope federated council) | Level 3 + GFAIC onboarding module + GAISC group-policy briefing | once on appointment |
| **GAISC member / liaison** (enterprise parent body) | Level 3 + GAISC charter briefing | once on appointment |

Completion is tracked in the existing HR LMS and reported to the
GCFO Finance AI Council (GFAIC) in the monthly pack
(`docs/governance/gcfo-finance-ai-council.md` §4). GFAIC operates under
delegated authority from the enterprise Group AI Safety Council
(GAISC); finance-scope training completion is reported up to GAISC via
GFAIC's monthly status pack.

## 3 Curriculum

### Level 1 — Awareness (45 min, asynchronous)

Mandatory for every employee exposed to agentic AI output. Delivered
as a short video plus a 10-question knowledge check.

Learning outcomes:

1. Recognise an agentic AI system when you see one — plans across
   multiple steps, calls tools, acts on external systems.
2. Distinguish a deterministic automation (an RPA bot) from an
   agentic AI system (an LLM-driven planner).
3. Name the three artifacts that bound every SAP OSS agent: its
   data-product allow-list, its tool allow-list, and its scope
   declaration (`read-only` vs `read-write`, tenant).
4. Know who to contact if you suspect an agent is misbehaving:
   the GCFO Finance AI Council inbox for Finance-scope agents
   (Chair 1-business-day triage); non-finance agents go to the peer
   council for that function, or to GAISC directly.

Assessment: 8 of 10 on the knowledge check.

### Level 2 — Reviewer skills (half-day, instructor-led)

Mandatory for reviewers and approvers. Delivered in a workshop format
with five live exercises using the golden-set from
`docs/tb/structured/golden-set/`.

Learning outcomes:

1. **Explain the jagged frontier.** Describe where agents outperform
   humans on SAP OSS tasks (volume, consistency, text quality) and
   where they underperform (novel edge cases, image/figure
   interpretation, ambiguous policy). Basis: Ju & Aral §3.
2. **Detect automation bias in yourself.** Use the self-check
   checklist (§3.4 below) before accepting any agent recommendation.
3. **Recognise the five MAS MGF decision-point categories.** Bound
   risks, bound resources, bound impact, bound actions, bound
   information — and what each of them means for your review.
4. **Invoke the trajectory evaluator.** Run
   `python3 -m evaluation.trajectory_evaluator` over a captured trace
   and read the three sub-scores.
5. **Escalate correctly.** Critical / material / routine triage per
   the Council's incident-review procedure.

Assessment: each learner reviews three trajectories from the
trial-balance golden-set, explains at least one override, and demos
the trajectory-evaluator invocation.

### Level 3 — Oversight depth (one day, instructor-led)

Mandatory for agent owners, approvers for CFO-bound packs, and
Council members. Two half-day sessions.

Session A — *Controls that bound the agent.*

1. Walk the data-product registry (`docs/tb/structured/data-products/`)
   and explain how a data-product record narrows an agent's blast
   radius.
2. Walk the MCP-server allow-list
   (`src/intelligence/ai-core-pal/mcp_server/`) and explain the
   consequence of adding or removing a tool.
3. Read the drift report produced by
   `src/intelligence/ai-core-pal/monitoring/drift_monitor.py`;
   interpret ok / warn / critical levels; rehearse the override-rate
   fall pattern from Ju & Aral.

Session B — *Governance and accountability.*

1. The GCFO Finance AI Council (GFAIC) charter and the parent Group
   AI Safety Council (GAISC) relationship: read both, discuss the
   federated model, run a tabletop incident-review exercise that
   includes a cross-function escalation from GFAIC up to GAISC.
2. The waiver process: walk one real Finance-scope waiver end-to-end
   including compensating controls, GFAIC vote, and GAISC ratification
   when the waiver exceeds 30 days.
3. Regulator interaction: how the validator report, GFAIC minutes
   extracts, the GAISC delegation instrument, and this charter map
   to a regulator's request.

Assessment: instructor-observed tabletop with a GFAIC member
present.

### 3.4 Reviewer self-check (pocket card)

A one-page printable checklist distributed at the end of Level 2.
Reviewers are expected to run through it before approving any agent
recommendation:

```
[ ] Did I read the agent's reasoning end-to-end before clicking approve?
[ ] Did I check at least one source document the agent cited?
[ ] Is my review time obviously shorter than usual? (If yes — slow down.)
[ ] Did the agent ask for a tool outside its usual allow-list?
[ ] Did the trajectory evaluator flag any violations?
[ ] Is the recommendation about a tenant / entity I do not normally review?
[ ] Am I the *only* human in the loop for this decision?
```

## 4 Delivery, tracking, and governance

- **Platform.** SuccessFactors LMS with tracked completion and quiz
  results.
- **Authoring.** Curriculum authored and maintained by the Chief Data
  & AI Office in this repository. Material updates trigger a new
  version and a Council review entry.
- **Reporting.** Monthly completion rate by persona in the Council
  pack; rolling 12-month completion KPI must stay ≥ 95 % for
  reviewers and approvers.
- **Evidence.** HR LMS export hashed and attached to the monthly
  minutes.
- **Accessibility.** All material available in English; translations
  on demand for Arabic-invoice reviewers (`docs/arabic/`) and Africa
  GFS (French) where local regulation requires.

## 5 Change log

| Version | Date | Author | Note |
| --- | --- | --- | --- |
| 1.0 | 2026-04-18 | Chief Data & AI Office | Initial ratified version, closes `REG-MGF-2.4.3-001`. |
