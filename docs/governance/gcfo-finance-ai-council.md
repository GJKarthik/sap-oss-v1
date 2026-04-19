# GCFO Finance AI Council — Charter

**Status:** ratified v1.0 (April 2026)
**Parent body:** Group AI Safety Council (GAISC)
**Delegation instrument:** GAISC Delegation No. 2026-04 (Finance function)
**Owner:** Group Chief Financial Officer
**Cadence:** monthly standing meeting; ad-hoc incident reviews within 5 business days
**Closes regulatory requirement:** `REG-MGF-2.2.1-002` (MAS MGF §2.2.1 — adaptive governance) for the Finance scope

## 1 Purpose and federated model

The GCFO Finance AI Council (GFAIC) is the **finance-function delegate**
of the enterprise-level Group AI Safety Council (GAISC). It holds
binding decision rights over agentic AI that operates inside the
Finance perimeter, exercised within the guard-rails that GAISC publishes
as group-wide policy.

```
               +----------------------------------------+
               |        Group AI Safety Council         |  enterprise policy,
               |        (GAISC -- parent body)          |  cross-function escalations
               +------------------+---------------------+
                                  | delegates binding authority per
                                  | GAISC Delegation No. 2026-04
           +----------------------+------------------------+
           |                      |                        |
 +---------v--------+   +---------v---------+   +----------v-----------+
 | GCFO Finance     |   | CHRO People AI    |   | CCO Customer AI      |
 | AI Council       |   | Council           |   | Council              |
 | (this charter)   |   | (peer)            |   | (peer -- reference)  |
 +------------------+   +-------------------+   +----------------------+
```

GFAIC's remit is **bounded to Finance**: agents operating on SAP OSS
infrastructure whose business owner sits within the Office of the
Group CFO. Today that covers:

- Trial-balance review (`docs/tb/`) — Africa GFS is the first tenant
- Arabic invoice / AP processing (`docs/arabic/`) — MEP region
- Any future Finance agentic use case registered with GFAIC

Anything outside Finance — People-function agents, Customer-facing
agents, product-embedded agents — is **out of scope**; GFAIC refers
such matters up to GAISC or sideways to the relevant peer council.

The Council exists to satisfy the MAS Model AI Governance Framework
for Agentic AI §2.2.1 expectation that organisations adopt
"adaptive governance" — named humans with the authority to **understand
new developments and update the organisation's approach** as the
technology evolves — within the Finance function specifically.

## 2 Authority (within delegated scope)

GFAIC has binding decision rights for agentic AI in the Finance scope
only. The authority matrix below applies **inside** that scope; cases
touching multiple functions are escalated to GAISC.

| Decision | Threshold | Escalation |
| --- | --- | --- |
| Approve a new Finance agentic use case for pilot | simple majority of voting members | GAISC notified in next monthly pack |
| Approve a pilot for production rollout | simple majority, with Head of Finance Risk concurrence | GAISC + Group CRO on dissent |
| Suspend a Finance agent in production | any Council member can unilaterally freeze pending review | GAISC informed within 1 business day; Council convenes within 5 BD |
| Adjust an agent's tool or data-product permission set (Finance-internal) | simple majority | quarterly summary to GAISC + Audit Committee |
| Waive a MAS MGF control (Finance scope only) | unanimous, time-boxed, with documented compensating control | GAISC ratification for any waiver > 30 days; Audit Committee for > 90 days |
| Any decision with cross-function implications | **not delegated** | escalate to GAISC for binding decision |

All binding decisions are taken within the group-wide guard-rails
published by GAISC (the *Group AI Safety Standard* and the
*Enterprise Agentic AI Policy*). GFAIC cannot weaken a group-level
control; it may only tighten it for the Finance scope.

## 3 Membership

Voting members (quorum = 4 of 6):

1. **Chair:** Group Chief Financial Officer (or delegate — typically
   Head of GFS Finance Operations).
2. **Head of Finance Risk & Controls** (or Finance Model Risk lead).
3. **Finance liaison to the CISO Office** (Head of Finance AppSec).
4. **Finance liaison to the General Counsel** (Finance & Tax Law).
5. **Head of Finance Internal Audit.**
6. **Finance AI technical lead** (Principal Engineer, AI Core PAL;
   same role that sits on GAISC as a non-voting Finance observer).

Standing invitees (non-voting):

- **GAISC Liaison** — appointed by the Chair of GAISC; ensures
  two-way flow between parent and federated body. Attends every
  GFAIC meeting.
- **Business sponsor of the agent under review** (rotating; trial
  balance review sponsor is Head of Africa GFS per
  `docs/tb/structured/workflows/tb-review-glo.json`; Arabic AP
  sponsor is Head of MEP AP Operations).
- **Data Protection Officer** (enterprise, shared with peer councils).
- **Head of Finance People Operations** (for human-oversight topics).
- **External advisor** (rotating panel maintained by GAISC).

Note the deliberate change from an enterprise-wide council: the
CRO, CISO, General Counsel, and Head of Internal Audit sit on
**GAISC**, not on GFAIC. Their Finance-function delegates carry
the vote here so the parent body retains enterprise oversight
without double-staffing.

## 4 Inputs to every meeting

Supplied 48 hours in advance in a standard pack:

1. **Validator report.** Output of
   `python3 docs/regulations/structured/validate.py` plus any
   regressions since prior meeting.
2. **Incident log.** Finance-scope agent-level incidents, overrides,
   and near-misses.
3. **KPI pack.** Override rates, review durations, and drift metrics
   from `src/intelligence/ai-core-pal/monitoring/drift_monitor.py`
   (see `REG-MGF-2.3.3-002`).
4. **New-use-case submissions.** Structured request referencing a
   draft entry in `docs/regulations/structured/requirements/` and the
   data-product record it depends on.
5. **GAISC bulletin.** Any group-wide policy update, peer-council
   finding, or cross-function incident that GAISC has flagged as
   relevant to Finance.
6. **Regulatory delta.** Any change detected in
   `docs/regulations/source/` (hash mismatch in `corpus.json`) or in
   vendored conformance tooling.

## 5 Decision record

Each meeting produces minutes stored at
`docs/governance/minutes/YYYY-MM-gfaic.md` and referenced from the
corresponding requirement record when a decision changes a
requirement's status. The standing fields are:

- date, attendees (incl. GAISC Liaison), quorum status
- decisions (bulleted; each with requirement IDs affected)
- actions (owner, due date)
- incidents reviewed and their disposition
- dissents and their reasoning
- items escalated to GAISC

A redacted copy of each set of minutes is shared with GAISC within
5 business days of the meeting.

## 6 Incident-review procedure

1. Any Council member, agent owner, or audit team may file an
   incident via the Council inbox.
2. Triage by the Chair within 1 business day: classified as
   *critical* (agent freeze until review), *material* (review within
   5 business days), or *routine* (next monthly meeting).
3. **Cross-function check.** If the incident has implications outside
   Finance (e.g. a Finance agent inadvertently touched HR data), the
   Chair escalates to GAISC for joint handling within 2 business days.
4. For *critical* incidents the Chair convenes an emergency session;
   the agent remains frozen until the Council releases it or approves
   a compensating control. GAISC Liaison must attend.
5. Post-review, the Council either: (a) clears the agent, (b)
   modifies its permissions or oversight, (c) keeps it frozen, or
   (d) decommissions it. The decision is recorded and — if it
   changes a requirement's evidence — reflected in
   `docs/regulations/structured/requirements/`.

## 7 Reporting lines

- **Up to GAISC:** monthly status pack (decisions, incidents, KPIs,
  waivers); ad-hoc escalation on cross-function matters within 2 BD.
- **To the Group Audit Committee:** quarterly summary, routed via
  GAISC, covering approvals, incidents, and any waivers in force.
- **To the Group CFO's leadership team:** monthly status update plus
  any suspended agents.
- **Sideways to peer federated councils (CHRO, CCO, etc.):** findings
  with potential peer relevance are circulated via GAISC, never
  directly, to preserve the federated model.
- **To Regulators:** on demand, jointly with GAISC, in the form of
  the validator report, minutes excerpts, the GAISC delegation
  instrument, and this charter.

## 8 Review, amendment, and delegation reconfirmation

- This charter is reviewed annually by GFAIC itself and every three
  years by an external reviewer appointed by GAISC. Amendments require
  a two-thirds vote **and** GAISC ratification; they are logged as a
  new version at the top of this document.
- The **delegation instrument** (GAISC Delegation No. 2026-04) is
  reconfirmed annually by GAISC. Lapse of the delegation instrument
  automatically returns binding authority to GAISC until a new
  instrument is issued.
- Any material change to the group-wide guard-rails published by
  GAISC takes effect in GFAIC at the next scheduled meeting, or
  sooner if GAISC designates the change urgent.
