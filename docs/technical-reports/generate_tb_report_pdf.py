#!/usr/bin/env python3
"""Generate PDF from the TB AI Specification using reportlab.

v1.1 -- addresses review feedback:
  - Widened Priority column (no truncation)
  - ABDO field gets business description
  - Error-handling states added to state machine
  - LLM commentary evaluation criteria (Section 1.3)
  - BSS RA integration point (Section 1.6)
  - Test scenarios table (Section 1.5)
  - DP-1 feedback loop + extraction SLA (Section 2.2)
  - ASCII decision flowchart (Section 2.1)
  - Audit trail fields in schema section (Section 3.3)
  - Phase handshake between extraction and analysis
"""

from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.colors import HexColor
from reportlab.lib.units import cm, mm
from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_JUSTIFY
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
    PageBreak, KeepTogether, Preformatted
)
from reportlab.lib import colors
from pathlib import Path

OUTPUT = Path(__file__).parent / "04-trial-balance-ai-specification.pdf"

# Colors
SAP_BLUE = HexColor("#0070F2")
SAP_DARK = HexColor("#354A5F")
SAP_GOLD = HexColor("#E78C07")
CRIT_RED = HexColor("#BB0000")
LIGHT_BG = HexColor("#F5F6F7")
WHITE = colors.white
BLACK = colors.black
GREY = HexColor("#666666")

styles = getSampleStyleSheet()

# Custom styles
styles.add(ParagraphStyle(
    "DocTitle", parent=styles["Title"], fontSize=22, leading=26,
    textColor=SAP_DARK, spaceAfter=6
))
styles.add(ParagraphStyle(
    "DocSubtitle", parent=styles["Normal"], fontSize=14, leading=18,
    textColor=SAP_BLUE, alignment=TA_CENTER, spaceAfter=4
))
styles.add(ParagraphStyle(
    "SectionHead", parent=styles["Heading1"], fontSize=16, leading=20,
    textColor=SAP_DARK, spaceBefore=20, spaceAfter=10,
    borderWidth=0, borderPadding=0
))
styles.add(ParagraphStyle(
    "SubHead", parent=styles["Heading2"], fontSize=13, leading=16,
    textColor=SAP_BLUE, spaceBefore=14, spaceAfter=8
))
styles.add(ParagraphStyle(
    "SubSubHead", parent=styles["Heading3"], fontSize=11, leading=14,
    textColor=SAP_DARK, spaceBefore=10, spaceAfter=6
))
styles.add(ParagraphStyle(
    "BodyText2", parent=styles["Normal"], fontSize=9.5, leading=13,
    alignment=TA_JUSTIFY, spaceAfter=6
))
styles.add(ParagraphStyle(
    "SmallText", parent=styles["Normal"], fontSize=8.5, leading=11,
    textColor=GREY
))
styles.add(ParagraphStyle(
    "TableCell", parent=styles["Normal"], fontSize=8.5, leading=11
))
styles.add(ParagraphStyle(
    "TableHeader", parent=styles["Normal"], fontSize=8.5, leading=11,
    textColor=WHITE, fontName="Helvetica-Bold"
))
styles.add(ParagraphStyle(
    "BulletItem", parent=styles["Normal"], fontSize=9.5, leading=13,
    leftIndent=12, spaceAfter=3
))
styles.add(ParagraphStyle(
    "Monospace", parent=styles["Normal"], fontName="Courier", fontSize=7.5,
    leading=10, leftIndent=12, spaceAfter=6
))


def P(text, style="BodyText2"):
    return Paragraph(text, styles[style])


def header_table(data, col_widths=None):
    """Create a styled table with SAP blue header."""
    t = Table(data, colWidths=col_widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), SAP_DARK),
        ("TEXTCOLOR", (0, 0), (-1, 0), WHITE),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE", (0, 0), (-1, 0), 8.5),
        ("FONTSIZE", (0, 1), (-1, -1), 8.5),
        ("LEADING", (0, 0), (-1, -1), 11),
        ("ALIGN", (0, 0), (-1, 0), "LEFT"),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("BACKGROUND", (0, 1), (-1, -1), WHITE),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [WHITE, LIGHT_BG]),
        ("GRID", (0, 0), (-1, -1), 0.5, HexColor("#CCCCCC")),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
    ]))
    return t


def bullet(text):
    return P(f"<bullet>&bull;</bullet> {text}", "BulletItem")


def mono_block(text):
    """Render a monospace pre-formatted block."""
    return Preformatted(text, styles["Monospace"])


def build():
    doc = SimpleDocTemplate(
        str(OUTPUT), pagesize=A4,
        leftMargin=2*cm, rightMargin=2*cm,
        topMargin=2.5*cm, bottomMargin=2*cm,
        title="Trial Balance Review - AI Specification",
        author="SAP OSS - Studio AI"
    )
    W = doc.width
    story = []

    # ─── Title Page ────────────────────────────────────────────────
    story.append(Spacer(1, 3*cm))
    story.append(P("Trial Balance Review", "DocTitle"))
    story.append(P("AI-Augmented Processing &amp; Analytics", "DocSubtitle"))
    story.append(Spacer(1, 0.5*cm))
    story.append(P("Detailed Business Requirements, Process Specification,<br/>and Training Data Design", "DocSubtitle"))
    story.append(Spacer(1, 1*cm))

    # Metadata box
    meta = [
        ["Process Owner", "Modi, Piyush"],
        ["Created By", "S1 Badrinath (1498002)"],
        ["Version", "1.1"],
        ["Date", "April 2026"],
        ["Classification", "Confidential"],
    ]
    mt = Table(meta, colWidths=[4*cm, 8*cm])
    mt.setStyle(TableStyle([
        ("FONTNAME", (0, 0), (0, -1), "Helvetica-Bold"),
        ("FONTSIZE", (0, 0), (-1, -1), 9),
        ("LEADING", (0, 0), (-1, -1), 14),
        ("TEXTCOLOR", (0, 0), (0, -1), SAP_DARK),
        ("LINEBELOW", (0, 0), (-1, -1), 0.3, HexColor("#DDDDDD")),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    story.append(mt)

    story.append(Spacer(1, 1.5*cm))
    story.append(P(
        "This document provides the detailed specification for AI-augmented Trial Balance (TB) review, "
        "covering the month-end close process across 234 legal entities. It consolidates the business "
        "requirements, formal process specification (state machine with 27 states and 5 decision gateways), "
        "training data design from the HKG TB/PL workbooks, and data schema definitions."
    ))
    story.append(PageBreak())

    # ─── TABLE OF CONTENTS ──────────────────────────────────────────
    story.append(P("Contents", "SectionHead"))
    toc_items = [
        "1. Business Requirements",
        "   1.1 Executive Summary",
        "   1.2 Scope &amp; Stakeholders",
        "   1.3 Process Steps with AI Augmentation",
        "   1.4 KPIs, Controls &amp; Risk Assessment",
        "   1.5 Implementation Timeline &amp; Test Scenarios",
        "   1.6 BSS Risk Assessment &amp; Integration Point",
        "2. Process Specification",
        "   2.1 State Machine (27 states, 5 gateways)",
        "   2.2 Decision Flowchart",
        "   2.3 Decision Point Logic &amp; Feedback Loops",
        "   2.4 Data Objects &amp; Participants",
        "3. Training Data Design &amp; Schema",
        "   3.1 Source Workbooks Overview",
        "   3.2 Key Schemas (Dept Mapping, Base File, GCOA)",
        "   3.3 Variance Analysis Data Model",
        "   3.4 Audit Trail &amp; Versioning",
        "4. Domain Glossary",
        "5. RAG &amp; Data Product Integration",
        "Appendix: File Inventory",
    ]
    for item in toc_items:
        indent = 18 if item.startswith("   ") else 0
        s = ParagraphStyle("TOC", parent=styles["Normal"], fontSize=10, leading=16, leftIndent=indent)
        story.append(Paragraph(item.strip(), s))
    story.append(PageBreak())

    # =================================================================
    # SECTION 1: BUSINESS REQUIREMENTS
    # =================================================================
    story.append(P("1. Business Requirements", "SectionHead"))

    story.append(P("1.1 Executive Summary", "SubHead"))
    story.append(P(
        "Trial Balance review is conducted during M+1 to M+7 across all Legal entities, "
        "Segment &amp; Group, to understand variance &amp; balance movements between periods. "
        "An AI model produces business insights and written commentaries based on GL transaction "
        "data analysis -- detecting anomalies, trends, unusual movements, new accounts, spikes/drops "
        "vs prior periods, and material balances."
    ))

    data = [
        ["Dimension", "Current State", "Target State"],
        ["FTE Effort", "20-25 FTEs, ~4 hrs/day", "15-20 FTEs (5 FTE savings)"],
        ["Cycle Time", "M+1 to M+7 (monthly)", "Daily control capability"],
        ["Reporting Views", "Legal Entity only", "LE + Caption + Segment"],
        ["Commentary", "Manual stakeholder requests", "LLM-generated drafts"],
        ["Controls", "EUC-dependent manual", "Automated with audit trail"],
        ["Investment", "--", "3 FTEs, <100 days"],
        ["Solution", "--", "Studio AI (in-house)"],
    ]
    story.append(header_table(data, [3.5*cm, 5.5*cm, 6.5*cm]))
    story.append(Spacer(1, 0.5*cm))

    story.append(P("1.2 Scope &amp; Stakeholders", "SubHead"))
    story.append(bullet("<b>In scope:</b> TB review at Finance caption level, variance analysis, automated commentary writing, segment &amp; LE reporting"))
    story.append(bullet("<b>Out of scope:</b> Country IFRS reporting, BSS Risk Assessment (covered separately in Section 1.6)"))
    story.append(bullet("<b>Coverage:</b> 234 legal entities across all segments and Group"))
    story.append(Spacer(1, 0.3*cm))

    stakeholders = [
        ["Role", "Responsibilities"],
        ["Process Owner (Modi, Piyush)", "Owns BPMN process definition; approves workflow changes"],
        ["Head of Africa GFS", "Internal review and approval; FORTM pack oversight"],
        ["Country Stakeholders", "Provide variance commentaries; confirm entry status by M+4"],
        ["GCFO Teams", "Consume narrative summaries; review and decision-making"],
        ["AI Architect", "Solution design (PSGL + S4 compatibility)"],
        ["PPE Team", "SAP integration assessment"],
    ]
    story.append(header_table(stakeholders, [5*cm, 10.5*cm]))
    story.append(Spacer(1, 0.5*cm))

    # Process Steps
    story.append(P("1.3 Process Steps with AI Augmentation Opportunities", "SubHead"))

    steps = [
        ["ID", "Step", "Timing", "Priority", "AI Augmentation Opportunity"],
        ["1", "Roll Forward Prior Month File", "M-3", "Medium",
         "Auto-generate template, pre-populate parameters, detect CoA changes"],
        ["2", "Download PSGL & Update Master", "M-3", "High",
         "Automated PSGL/S4 extraction via API; auto-detect new/changed accounts"],
        ["3", "Extract Trial Balance", "M-3 to M+5", "Critical",
         "Automated pipeline from PSGL/S4; support all 234 LEs in parallel"],
        ["4", "Calculate & Filter Variances", "M-2 to M+5", "Critical",
         "ML-based materiality thresholds; anomaly detection; multi-dimensional analysis"],
        ["5", "Seek & Update Commentaries", "M-2 to M+5", "Critical",
         "LLM-generated draft commentaries from GL data and historical patterns"],
        ["6", "Journal Posting & Investigation", "M-2 to M+5", "High",
         "Auto-detect unposted journals; predict investigation need"],
        ["7", "Track Entries & Risk Assessment", "M-2 to M+5", "High",
         "Predictive risk scoring; NLP variance categorization; real-time dashboard"],
        ["8", "Prepare Summary & Review", "M+5", "Critical",
         "Auto-generate narrative; FORTM pack section; multi-user collaborative review"],
    ]
    # Convert to Paragraphs for wrapping -- FIX: wider Priority column
    psteps = []
    for i, row in enumerate(steps):
        if i == 0:
            psteps.append([Paragraph(c, styles["TableHeader"]) for c in row])
        else:
            priority_color = {"Critical": "#BB0000", "High": "#E78C07", "Medium": "#0070F2"}.get(row[3], "#000000")
            prow = [
                Paragraph(row[0], styles["TableCell"]),
                Paragraph(row[1], styles["TableCell"]),
                Paragraph(row[2], styles["TableCell"]),
                Paragraph(f'<font color="{priority_color}"><b>{row[3]}</b></font>', styles["TableCell"]),
                Paragraph(row[4], styles["TableCell"]),
            ]
            psteps.append(prow)
    story.append(header_table(psteps, [0.8*cm, 2.8*cm, 1.8*cm, 1.6*cm, 8.5*cm]))
    story.append(Spacer(1, 0.3*cm))

    # LLM Commentary Evaluation Criteria (NEW)
    story.append(P("<b>LLM Commentary Evaluation Criteria</b>", "BodyText2"))
    story.append(P(
        "Step 5 (Seek &amp; Update Commentaries) introduces LLM-generated draft commentaries. "
        "Acceptance criteria for production deployment:"
    ))
    llm_eval = [
        ["Metric", "Target", "Measurement Method"],
        ["Human acceptance rate", ">85% require only minor edits", "Monthly sample of 50 commentaries, rated by GFS analysts"],
        ["Factual accuracy", "100% of referenced figures match GL", "Automated cross-check against variance file balances"],
        ["Coverage", "100% of material variances receive a draft", "Count of drafts vs. material variance count"],
        ["Latency", "<30 seconds per commentary", "P95 latency from RAG retrieval + generation pipeline"],
        ["Feedback loop", "Monthly retraining on accepted/rejected drafts", "Analyst edits stored as preference signal for RLHF"],
    ]
    peval = []
    for i, row in enumerate(llm_eval):
        st = styles["TableHeader"] if i == 0 else styles["TableCell"]
        peval.append([Paragraph(c, st) for c in row])
    story.append(header_table(peval, [3.2*cm, 4.5*cm, 7.8*cm]))
    story.append(Spacer(1, 0.5*cm))

    # KPIs
    story.append(P("1.4 KPIs, Controls &amp; Risk Assessment", "SubHead"))
    story.append(P("Key Performance Indicators", "SubSubHead"))

    kpis = [
        ["KPI", "Description", "Current", "Target"],
        ["TB-KPI-001", "Variance materiality threshold", "Country-specific", "ML-adaptive"],
        ["TB-KPI-002", "Review cycle time (days)", "7 days", "Daily capable"],
        ["TB-KPI-003", "Commentary coverage rate", "Variable", "100%"],
        ["TB-KPI-004", "FTE effort", "20-25 FTEs", "15-20 FTEs"],
        ["TB-KPI-005", "Unexplained variance rate", "Non-zero", "0%"],
        ["TB-KPI-006", "EUC control compliance", "Manual", "100% automated"],
        ["TB-KPI-007", "LLM commentary acceptance rate", "N/A", ">85%"],
    ]
    story.append(header_table(kpis, [2.5*cm, 5*cm, 3.5*cm, 4.5*cm]))
    story.append(Spacer(1, 0.3*cm))

    story.append(P("EUC Control Matrix", "SubSubHead"))
    ctrls = [
        ["Control ID", "EUC Reference", "Objective", "Freq."],
        ["TB-CTRL-001", "EX/200/1353107/0001/000", "PSGL master data extraction integrity", "Monthly"],
        ["TB-CTRL-002", "EX/200/1579702/0001/000", "Variance analysis calculation accuracy", "Monthly"],
        ["TB-CTRL-003", "EX/200/1579702/0002/000", "Senior review before FORTM submission", "Monthly"],
    ]
    story.append(header_table(ctrls, [2.5*cm, 4.5*cm, 6.5*cm, 2*cm]))
    story.append(Spacer(1, 0.3*cm))

    story.append(P("Risk Register", "SubSubHead"))
    risks = [
        ["ID", "Risk", "AI Mitigation", "Sev."],
        ["CR-001", "Manual extraction errors/EUC risks", "Automated extraction eliminates manual handling", "H"],
        ["CR-002", "Delayed commentary responses", "Auto-generated draft commentaries", "M"],
        ["CR-003", "Incomplete analysis (time constraints)", "AI anomaly detection across all 234 LEs", "H"],
        ["CR-004", "Not scalable to daily controls", "Foundation for daily automated monitoring", "M"],
        ["CR-005", "PSGL/S4 API failure during parallel extraction", "Retry with exponential backoff; manual EUC override state", "H"],
        ["CR-006", "LLM commentary hallucination", "Factual cross-check against GL + human review gate", "H"],
    ]
    prisk = []
    for i, row in enumerate(risks):
        if i == 0:
            prisk.append([Paragraph(c, styles["TableHeader"]) for c in row])
        else:
            prisk.append([Paragraph(c, styles["TableCell"]) for c in row])
    story.append(header_table(prisk, [1.5*cm, 4.5*cm, 7.5*cm, 1.5*cm]))
    story.append(Spacer(1, 0.5*cm))

    # Implementation + Test Scenarios
    story.append(P("1.5 Implementation Timeline (15 weeks) &amp; Test Scenarios", "SubHead"))
    impl = [
        ["Phase", "Duration", "Key Activities", "Milestone"],
        ["1. Planning", "1 week", "Business Requirements", "BRD finalisation"],
        ["2. Design", "2 weeks", "Process design, RACI, FRD", "Solution design"],
        ["3. Development", "5 weeks", "Solution development", "Working solution"],
        ["4. Testing", "5 weeks", "UAT, scenario testing, LLM eval", "Test completion"],
        ["5. SIT/Governance", "2 weeks", "Stress testing, governance", "Governance approval"],
        ["6. Go Live", "1 week", "Production deployment", "Production"],
    ]
    story.append(header_table(impl, [3*cm, 2.5*cm, 5*cm, 5*cm]))
    story.append(Spacer(1, 0.3*cm))

    # Test scenarios table (NEW)
    story.append(P("Key Test Scenarios (Phase 4)", "SubSubHead"))
    tests = [
        ["ID", "Scenario", "Expected Outcome", "Priority"],
        ["TS-001", "New GL account appears in current month (not in prior)", "Flagged as new account; variance = 100%; commentary drafted", "Critical"],
        ["TS-002", "Variance > $100M BS threshold with no commentary", "Auto-escalation to stakeholder; dashboard alert", "Critical"],
        ["TS-003", "PL variance > $3M with existing commentary", "Commentary displayed; no escalation", "High"],
        ["TS-004", "Journal required but not posted by M+3", "Auto-detect from GL; investigation state triggered", "High"],
        ["TS-005", "PSGL/S4 API timeout during extraction for 1 of 234 LEs", "Retry 3x with backoff; remaining LEs unaffected; manual override", "Critical"],
        ["TS-006", "Zero balance in prior and current period", "Excluded from variance analysis; no commentary", "Medium"],
        ["TS-007", "Intercompany elimination entries (reversed signs)", "Correctly netted; not flagged as anomaly", "High"],
        ["TS-008", "LLM commentary references incorrect balance", "Factual cross-check rejects draft; flagged for manual write", "Critical"],
        ["TS-009", "All variances explained -- no unexplained remaining", "Proceed directly to PREPARE_SUMMARY; skip categorization", "Medium"],
        ["TS-010", "Country stakeholder does not confirm by M+4", "Auto-escalation; entry tracked in risk register", "High"],
    ]
    ptests = []
    for i, row in enumerate(tests):
        if i == 0:
            ptests.append([Paragraph(c, styles["TableHeader"]) for c in row])
        else:
            priority_color = {"Critical": "#BB0000", "High": "#E78C07", "Medium": "#0070F2"}.get(row[3], "#000000")
            ptests.append([
                Paragraph(row[0], styles["TableCell"]),
                Paragraph(row[1], styles["TableCell"]),
                Paragraph(row[2], styles["TableCell"]),
                Paragraph(f'<font color="{priority_color}"><b>{row[3]}</b></font>', styles["TableCell"]),
            ])
    story.append(header_table(ptests, [1.3*cm, 4.5*cm, 7.5*cm, 1.7*cm]))
    story.append(Spacer(1, 0.5*cm))

    # BSS with integration point (UPDATED)
    story.append(P("1.6 BSS Risk Assessment &amp; Integration Point", "SubHead"))
    story.append(P(
        "The BSS Risk Assessment is conducted during M+12 to M+15 across all Legal entities, "
        "critical for CFO attestation and Risk/Audit committee reporting."
    ))
    story.append(bullet("<b>Risk Categories:</b> Substantiated at Risk, Unsubstantiated Unowned, Unsubstantiated Owned"))
    story.append(bullet("<b>AI Capabilities:</b> Highlight high-risk GL accounts, suggest risk ratings, detect anomalies in balances/ageing/adjustments"))
    story.append(bullet("<b>FTE Impact:</b> 10-12 FTEs current, 1 FTE savings"))
    story.append(bullet("<b>Scope:</b> In: BSS Risk Assessment. Out: FORTM, BSS Reconciliations"))
    story.append(Spacer(1, 0.3*cm))

    story.append(P("<b>Integration with TB Workflow:</b>", "BodyText2"))
    story.append(P(
        "BSS Risk Assessment branches from the main TB workflow at the <b>UPDATE_RISK</b> state. "
        "When risk scores from the TB analysis phase exceed the BSS materiality threshold, "
        "the workflow triggers a <b>BSS_RA_SUBPROCESS</b> that runs as a deferred sub-process "
        "(M+12 to M+15). Data flow: UPDATE_RISK produces a risk register per LE; the BSS sub-process "
        "consumes this register plus historical ageing data to produce the CFO attestation pack. "
        "The integration is one-directional -- BSS results do not feed back into the current-month "
        "TB review but are available for the next cycle's anomaly detection baseline."
    ))
    story.append(PageBreak())

    # =================================================================
    # SECTION 2: PROCESS SPECIFICATION
    # =================================================================
    story.append(P("2. Process Specification", "SectionHead"))
    story.append(P(
        "The TB review follows a formal BPMN workflow (source: Operation of Month End Close Controls -- "
        "Trial Balance Review -- GLO). The workflow comprises <b>27 states</b> (including 3 error-handling states), "
        "<b>5 exclusive gateways</b>, and spans <b>4 timeline phases</b>."
    ))

    # Timeline with handshake note
    timeline = [
        ["Phase", "Timing", "Description"],
        ["Preparation", "M-3", "Setup: roll forward file, update parameters and master data"],
        ["Extraction", "M-3 to M+5", "Extract TB from PSGL/S4 and load into variance analysis file"],
        ["Extraction->Analysis handshake", "M-2", "UPDATE_TB_DETAILS completes; triggers CALCULATE_VARIANCE"],
        ["Analysis", "M-2 to M+5", "Variance calculation, commentary collection, investigation, risk"],
        ["Review", "M+5", "Internal review, incorporate changes, send FORTM pack"],
    ]
    story.append(header_table(timeline, [4.5*cm, 2.5*cm, 8.5*cm]))
    story.append(Spacer(1, 0.3*cm))

    story.append(P(
        "<b>Phase overlap:</b> Extraction (M-3 to M+5) and Analysis (M-2 to M+5) overlap because "
        "extraction runs per-LE on a rolling basis. Analysis begins as soon as the first batch of LEs "
        "complete extraction (M-2). The handshake state UPDATE_TB_DETAILS acts as the trigger: once TB "
        "details are loaded into the variance file for a given LE, that LE enters the analysis phase. "
        "LEs still awaiting extraction continue in parallel."
    ))
    story.append(Spacer(1, 0.3*cm))

    story.append(P("2.1 State Machine", "SubHead"))

    # Preparation phase
    story.append(P("Preparation Phase (M-3)", "SubSubHead"))
    for item in [
        "<b>START</b> -- Prepare Schedule Work Day",
        "<b>ROLL_FORWARD</b> -- Roll Forward Prior Month File [MS Excel, Shared Drive]",
        "<b>DOWNLOAD_PSGL</b> -- Download PSGL Master Account File [PSGL, MS Excel]",
        "<b>UPDATE_ACCOUNTS_MASTER</b> -- Update Accounts Master Sheet [MS Excel]",
        "<b>UPDATE_PARAMETERS</b> -- Update Parameters &amp; Comparatives [MS Excel]",
    ]:
        story.append(bullet(item))

    story.append(P("Extraction Phase (M-3 to M+5)", "SubSubHead"))
    for item in [
        "<b>EXTRACT_TB</b> -- Extract Trial Balance [SC Bridge, MS Excel]",
        "<b>VALIDATE_EXTRACTION</b> -- Verify row counts, checksums, and LE completeness [Automated]",
        "<b>UPDATE_TB_DETAILS</b> -- Update TB Details in Variance File [MS Excel, Shared Drive] EUC: EX/200/1579702/0001/000",
    ]:
        story.append(bullet(item))

    # Error-handling states (NEW)
    story.append(P("Error Handling (any phase)", "SubSubHead"))
    for item in [
        "<b>RETRY_EXTRACTION</b> -- Retry failed PSGL/S4 API call with exponential backoff (max 3 retries, 30s/60s/120s) [Automated]",
        "<b>ESCALATE_API_FAILURE</b> -- Alert GFS Analyst after 3 failed retries; log to incident tracker; enable manual EUC override [MS Outlook, ITSM]",
        "<b>MANUAL_OVERRIDE</b> -- GFS Analyst manually extracts data via EUC spreadsheet; flags LE for post-hoc reconciliation [MS Excel]",
    ]:
        story.append(bullet(item))

    story.append(P("Analysis Phase (M-2 to M+5)", "SubSubHead"))
    for item in [
        "<b>CALCULATE_VARIANCE</b> -- Calculate Period-over-Period Variance [MS Excel]",
        "<b>FILTER_VARIANCES</b> -- Filter by Materiality Criteria [MS Excel]",
        '<b>CHECK_MATERIAL_VARIANCES</b> [Gateway] -- Material? Yes->SEEK_COMMENTARIES | No->CHECK_UNEXPLAINED',
        "<b>SEEK_COMMENTARIES</b> -- Request Explanations [MS Outlook]",
        "<b>RECEIVE_COMMENTARIES</b> -- Collect Responses [Event]",
        "<b>UPDATE_COMMENTARIES</b> -- Record in Variance File [MS Excel]",
        '<b>IS_JOURNAL_POSTED</b> [Gateway] -- Posted->CHECK_UNEXPLAINED | Required->SEND_REQUEST | Not Posted->INVESTIGATE',
        "<b>SEND_JOURNAL_REQUEST</b> -- Request Posting [MS Outlook]",
        '<b>CHECK_FURTHER_INVESTIGATION</b> [Gateway] -- No->CHECK_UNEXPLAINED | Yes->CHECK_ENTRIES',
        "<b>CHECK_ENTRIES_STATUS</b> -- Follow Up with Teams [MS Outlook]",
        '<b>CHECK_CONFIRMATION</b> [Gateway] -- By M+4? Yes->CHECK_UNEXPLAINED | No->TRACK_ENTRIES',
        "<b>TRACK_ENTRIES</b> -- Track and Risk Analysis [MS Excel]",
        "<b>UPDATE_RISK</b> -- Update Risk Assessment [MS Excel] (BSS RA sub-process trigger)",
        '<b>CHECK_UNEXPLAINED</b> [Gateway] -- None->PREPARE_SUMMARY | Yes->CATEGORIZE',
        "<b>CATEGORIZE_UNEXPLAINED</b> -- Classify Unexplained Variances [MS Excel]",
    ]:
        story.append(bullet(item))

    story.append(P("Review Phase (M+5)", "SubSubHead"))
    for item in [
        "<b>PREPARE_SUMMARY</b> -- Consolidate Analysis [MS Excel]",
        "<b>SEND_INTERNAL_REVIEW</b> -- Submit for Review [MS Outlook, Shared Drive]",
        "<b>REVIEW_INCORPORATE</b> -- Incorporate Changes [MS Excel] EUC: EX/200/1579702/0002/000",
        "<b>SEND_FORTM</b> -- Submit FORTM Pack [MS Outlook, Shared Drive]",
        "<b>END</b> -- TB Review Completed for Month",
    ]:
        story.append(bullet(item))
    story.append(Spacer(1, 0.5*cm))

    # Decision flowchart (NEW)
    story.append(P("2.2 Decision Flowchart", "SubHead"))
    story.append(P(
        "The following diagram shows the 5 exclusive gateways and their branching logic. "
        "Error-handling states (dashed) can trigger from any extraction or API-dependent state."
    ))
    flowchart = """\
START -> ROLL_FORWARD -> DOWNLOAD_PSGL -> UPDATE_ACCOUNTS_MASTER
  -> UPDATE_PARAMETERS -> EXTRACT_TB -> VALIDATE_EXTRACTION
  -> UPDATE_TB_DETAILS -> CALCULATE_VARIANCE -> FILTER_VARIANCES

  [GW1: CHECK_MATERIAL_VARIANCES]
    |-- Material? YES --> SEEK_COMMENTARIES --> RECEIVE
    |                     --> UPDATE_COMMENTARIES
    |-- Material? NO  --------------------------> [GW5]

  [GW2: IS_JOURNAL_POSTED]
    |-- Posted     --------------------------> [GW5]
    |-- Required   --> SEND_JOURNAL_REQUEST --> [GW3]
    |-- Not Posted --> INVESTIGATE -----------> [GW3]

  [GW3: CHECK_FURTHER_INVESTIGATION]
    |-- No  ---------------------------------> [GW5]
    |-- Yes --> CHECK_ENTRIES_STATUS ---------> [GW4]

  [GW4: CHECK_CONFIRMATION]
    |-- By M+4? YES -------------------------> [GW5]
    |-- By M+4? NO  --> TRACK_ENTRIES
                        --> UPDATE_RISK ------> [GW5]

  [GW5: CHECK_UNEXPLAINED]
    |-- None -------> PREPARE_SUMMARY --> SEND_REVIEW
    |                   --> REVIEW_INCORPORATE --> SEND_FORTM --> END
    |-- Has unexpl --> CATEGORIZE_UNEXPLAINED --> PREPARE_SUMMARY

  --- Error path (from EXTRACT_TB / DOWNLOAD_PSGL) ---
  API_FAIL --> RETRY_EXTRACTION (x3)
           --> ESCALATE_API_FAILURE --> MANUAL_OVERRIDE"""

    story.append(mono_block(flowchart))
    story.append(Spacer(1, 0.5*cm))

    # Decision points with feedback loops (UPDATED)
    story.append(P("2.3 Decision Point Logic &amp; Feedback Loops", "SubHead"))
    dp = [
        ["ID", "Decision", "Input Metric", "Condition", "AI Augmentation"],
        ["DP-1", "Material Variance", "variance_amount", "Exceeds threshold", "ML threshold tuning"],
        ["DP-2", "Journal Status", "journal_status", "posted/required/not", "Auto-detect from GL"],
        ["DP-3", "Investigation", "investigation_status", "Required / not", "Predict from entry history"],
        ["DP-4", "Entry Confirmation", "confirmation_received", "By M+4 deadline", "Auto-escalate deadline"],
        ["DP-5", "Unexplained Vars", "unexplained_count", "Zero / non-zero", "LLM draft commentaries"],
    ]
    pdp = []
    for i, row in enumerate(dp):
        st = styles["TableHeader"] if i == 0 else styles["TableCell"]
        pdp.append([Paragraph(c, st) for c in row])
    story.append(header_table(pdp, [1.2*cm, 2.8*cm, 3*cm, 3*cm, 5.5*cm]))
    story.append(Spacer(1, 0.3*cm))

    # DP-1 feedback loop (NEW)
    story.append(P("<b>DP-1 Threshold Feedback Loop:</b>", "BodyText2"))
    story.append(P(
        "The ML-adaptive materiality threshold (DP-1) is trained on historical variance distributions "
        "per LE and Finance Caption. The feedback loop operates as follows: (1) At month-end, the current "
        "threshold classifies variances as material/non-material. (2) Analysts override classifications "
        "during the review (marking false positives/negatives). (3) Override data is stored as labelled "
        "training samples. (4) Monthly batch retrain updates the threshold model using the last 12 months "
        "of override history. (5) New thresholds are deployed for the next cycle with a comparison report "
        "showing threshold drift. Initial deployment uses the current country-specific static thresholds "
        "(BS: $100M, PL: $3M) as the baseline."
    ))
    story.append(Spacer(1, 0.3*cm))

    # Extraction SLA (NEW)
    story.append(P("<b>234-LE Parallel Extraction SLA:</b>", "BodyText2"))
    extraction_sla = [
        ["Parameter", "Value"],
        ["Concurrency", "20 parallel LE extractions (rate-limited)"],
        ["Expected rows/LE", "5,000-50,000 GL lines"],
        ["Timeout per LE", "300 seconds"],
        ["Retry policy", "3 retries, exponential backoff (30s, 60s, 120s)"],
        ["Total extraction SLA", "<4 hours for all 234 LEs"],
        ["Fallback", "Manual EUC override for failed LEs"],
    ]
    story.append(header_table(extraction_sla, [4*cm, 11.5*cm]))
    story.append(Spacer(1, 0.5*cm))

    # Data objects & participants
    story.append(P("2.4 Data Objects &amp; Participants", "SubHead"))
    dos = [
        ["ID", "Object", "Description"],
        ["DO-001", "MS Excel Variance File", "Primary working file (EUC: EX/200/1579702/0001/000)"],
        ["DO-002", "Shared Drive", "Central file storage for TB review artifacts"],
        ["DO-003", "PSGL Master File", "Primary Subledger/General Ledger master data"],
        ["DO-004", "SC Bridge", "System interface for TB data extraction"],
        ["DO-005", "FORTM Pack", "Financial Operations Review & Tracking Monthly"],
        ["DO-006", "Incident Tracker (ITSM)", "API failure logging and escalation (new)"],
    ]
    story.append(header_table(dos, [2*cm, 4*cm, 9.5*cm]))
    story.append(Spacer(1, 0.3*cm))

    parts = [
        ["Participant", "Role", "Responsibility"],
        ["GFS Analyst", "Primary Executor", "TB extraction, variance analysis, summary preparation"],
        ["Head of Africa GFS", "Reviewer", "Reviews and approves before FORTM submission"],
        ["Country Stakeholders", "Commentary Providers", "Variance explanations, entry confirmations"],
    ]
    story.append(header_table(parts, [4*cm, 3.5*cm, 8*cm]))
    story.append(PageBreak())

    # =================================================================
    # SECTION 3: TRAINING DATA DESIGN & SCHEMA
    # =================================================================
    story.append(P("3. Training Data Design &amp; Schema", "SectionHead"))

    story.append(P("3.1 Source Workbooks", "SubHead"))
    wbs = [
        ["Workbook ID", "Name", "Size", "Sheets"],
        ["hkg-tb", "HKG TB Review Nov 2025", "73.4 MB", "13"],
        ["hkg-pl", "HKG PL Review Nov 2025", "50.8 MB", "14"],
    ]
    story.append(header_table(wbs, [3*cm, 5.5*cm, 3*cm, 4*cm]))
    story.append(Spacer(1, 0.3*cm))

    # TB sheet inventory
    story.append(P("HKG TB Review -- Sheet Inventory", "SubSubHead"))
    sheets = [
        ["Sheet Name", "Fields", "Purpose"],
        ["IFRS Summary BS", "--", "IFRS balance sheet summary view"],
        ["Count of Comments", "7", "Commentary tracking (reviewer, status, hours)"],
        ["Checklist", "--", "Review checklist"],
        ["BS Variance", "5", "Balance sheet variance analysis with thresholds"],
        ["PL Variance", "4", "P&L variance analysis"],
        ["YTD-TB", "--", "Year-to-date trial balance"],
        ["Rates", "2", "FX rates (Nov vs Oct 2025 USD)"],
        ["RAW TB NOV'25", "5", "Raw GL balance query -- November 2025"],
        ["RAW TB OCT'25", "5", "Raw GL balance query -- October 2025"],
        ["GCOA", "5", "Global Chart of Accounts (definitions, IFRS/MR mappings)"],
        ["Dept Mapping", "12", "Department-to-vertical mapping"],
        ["Base file", "13", "Account-level base data with all dimensional mappings"],
    ]
    psheets = []
    for i, row in enumerate(sheets):
        st = styles["TableHeader"] if i == 0 else styles["TableCell"]
        psheets.append([Paragraph(c, st) for c in row])
    story.append(header_table(psheets, [3.5*cm, 1.5*cm, 10.5*cm]))
    story.append(Spacer(1, 0.5*cm))

    # 3.2 Key schemas
    story.append(P("3.2 Key Schemas", "SubHead"))

    story.append(P("Dept Mapping Schema (12 fields)", "SubSubHead"))
    dm = [
        ["Technical Name", "Business Name", "Type", "Field Type", "Samples"],
        ["ACCOUNT", "Account", "INTEGER", "identifier", "111101"],
        ["ACCOUNT_DESC", "Account Desc", "NVARCHAR", "identifier", "Cash in Hand"],
        ["DEPT_ID", "Dept ID", "NVARCHAR", "identifier", "1424, 1428"],
        ["DEPT_ID_DESC", "Dept ID Desc", "NVARCHAR", "identifier", "BB District-HKI East"],
        ["PRODUCT", "Product", "INTEGER", "dimension", "259"],
        ["PRODUCT_DESC", "Product Desc", "NVARCHAR", "dimension", "Other AMS services"],
        ["CONCAT", "CONCAT", "NVARCHAR", "dimension", "1424259"],
        ["VERTICAL_FINAL", "Vertical final", "NVARCHAR", "dimension", "WRB - Retail"],
        ["VERTICAL", "Vertical", "NVARCHAR", "dimension", "CPBB - Retail"],
        ["OPER_UNIT", "Oper Unit", "INTEGER", "dimension", "156, 158"],
        ["OPER_UNIT_DESC", "Oper Unit Desc", "NVARCHAR", "dimension", "North Point Centre Branch"],
        ["VERTICAL_PB", "Vertical PB", "NVARCHAR", "dimension", "Retail Products"],
    ]
    pdm = []
    for i, row in enumerate(dm):
        st = styles["TableHeader"] if i == 0 else styles["TableCell"]
        pdm.append([Paragraph(c, st) for c in row])
    story.append(header_table(pdm, [3*cm, 2.8*cm, 2*cm, 2*cm, 5.5*cm]))
    story.append(Spacer(1, 0.5*cm))

    story.append(P("Base File Schema (13 fields)", "SubSubHead"))
    bf = [
        ["Technical Name", "Business Name", "Type", "Field Type", "Samples"],
        # FIX: ABDO gets proper business description
        ["ABDO", "Acct-Branch-Dept-OpUnit Key", "NVARCHAR", "identifier", "111101-238-1424-156"],
        ["ACCOUNT", "Account", "INTEGER", "identifier", "111101"],
        ["ACCOUNT_DESC", "Account Desc", "NVARCHAR", "identifier", "Cash in Hand"],
        ["DEPT_ID", "Dept ID", "INTEGER", "identifier", "1424, 1428"],
        ["DEPT_ID_DESC", "Dept ID Desc", "NVARCHAR", "identifier", "BB District-HKI East"],
        ["BUSS_MAPPING", "Buss Mapping", "NVARCHAR", "dimension", "1424259"],
        ["FINAL_MAPPING", "Final Mapping", "NVARCHAR", "dimension", "WRB - Retail"],
        ["VERTICAL", "Vertical", "NVARCHAR", "dimension", "WRB - Retail"],
        ["OPER_UNIT", "Oper Unit", "INTEGER", "dimension", "156, 158"],
        ["OPER_UNIT_DESC", "Oper Unit Desc", "NVARCHAR", "dimension", "North Point Centre Branch"],
        ["PRODUCT", "Product", "INTEGER", "dimension", "259"],
        ["PRODUCT_DESC", "Product Desc", "NVARCHAR", "dimension", "Other AMS services"],
        ["VERTICAL_2", "Vertical (PB)", "NVARCHAR", "dimension", "CPBB - Retail"],
    ]
    pbf = []
    for i, row in enumerate(bf):
        st = styles["TableHeader"] if i == 0 else styles["TableCell"]
        pbf.append([Paragraph(c, st) for c in row])
    story.append(header_table(pbf, [3*cm, 3.3*cm, 2*cm, 1.7*cm, 5.3*cm]))
    story.append(Spacer(1, 0.5*cm))

    story.append(P("GCOA Schema (Global Chart of Accounts)", "SubSubHead"))
    gcoa = [
        ["Field", "Type", "Description"],
        ["DEFINITION", "NVARCHAR", "Account definition text"],
        ["IFRS_PACK_MAPPING", "NVARCHAR", "IFRS Pack Schedule Reference (1A, 2A, etc.)"],
        ["MR_PACK_REFERENCE", "NVARCHAR", "MR Pack Schedule Reference (GP7, etc.)"],
        ["RETAIL_CUBE_MAPPING", "NVARCHAR", "Retail Cube mapping code"],
        ["FCP_CATEGORY", "NVARCHAR", "FCP Category (OTHER GL - NO AGEING, etc.)"],
    ]
    story.append(header_table(gcoa, [4*cm, 2.5*cm, 9*cm]))
    story.append(Spacer(1, 0.5*cm))

    # 3.3 Variance analysis
    story.append(P("3.3 Variance Analysis Data Model", "SubHead"))
    story.append(P("BS Variance Schema", "SubSubHead"))
    bsv = [
        ["Field", "Type", "Description"],
        ["Count of Variances", "NVARCHAR", "Category (Asset/Liability) and IFRS description"],
        ["IFRS Pack Sch Desc", "NVARCHAR", "IFRS schedule (Cash & Bal., Derivatives, etc.)"],
        ["BS Threshold", "INTEGER/%", "Variance threshold percentage"],
        ["Exceeds $100mn", "NVARCHAR", "Yes/No flag for $100M materiality"],
        ["Variance Explanation", "NVARCHAR", "Free-text commentary (LLM generation target)"],
    ]
    story.append(header_table(bsv, [3.5*cm, 2.5*cm, 9.5*cm]))
    story.append(Spacer(1, 0.3*cm))

    story.append(P(
        "<b>Key observations:</b> BS threshold is $100M; PL threshold is $3M. "
        "Commentaries reference specific business events and desk-level activity. "
        "IFRS Pack Schedule groupings provide the 'Finance Caption' view. "
        "Dept Mapping provides segment/vertical/product dimensional breakdowns."
    ))
    story.append(Spacer(1, 0.3*cm))

    # Training artifacts
    story.append(P("Training Data Artifacts", "SubSubHead"))
    ta = [
        ["File", "Description"],
        ["hkg-tb-schema.yaml", "Full ODPS 4.1 schema for 9 key sheets (58 fields)"],
        ["hkg-pl-schema.yaml", "Full ODPS 4.1 schema for 8 key sheets (48 fields)"],
        ["hkg-tb-sample.csv", "100 rows from BS Variance (header + data)"],
        ["hkg-pl-sample.csv", "100 rows from PL Variance (header + data)"],
    ]
    story.append(header_table(ta, [4.5*cm, 11*cm]))
    story.append(Spacer(1, 0.3*cm))

    story.append(P(
        "<b>Edge cases in sample data:</b> The 100-row samples include representative cases but "
        "production testing should cover: zero balances in both periods, reversed-sign intercompany "
        "eliminations, new accounts with no prior-period comparator, and multi-currency FX revaluation entries."
    ))
    story.append(Spacer(1, 0.5*cm))

    # 3.4 Audit trail (NEW)
    story.append(P("3.4 Audit Trail &amp; Versioning", "SubHead"))
    story.append(P(
        "Every record produced by the AI pipeline must carry audit metadata for EUC compliance and "
        "regulatory traceability. The following fields are appended to all output tables:"
    ))
    audit = [
        ["Field", "Type", "Description"],
        ["audit_id", "UUID", "Unique identifier for this processing run"],
        ["version", "INTEGER", "Monotonic version counter per LE per month (1, 2, 3...)"],
        ["processed_at", "TIMESTAMP", "ISO 8601 timestamp of pipeline execution"],
        ["processed_by", "NVARCHAR", "System user or service account ID"],
        ["source_hash", "NVARCHAR", "SHA-256 hash of input file for integrity verification"],
        ["override_flag", "BOOLEAN", "True if this record was manually overridden (MANUAL_OVERRIDE state)"],
    ]
    story.append(header_table(audit, [3*cm, 2.5*cm, 10*cm]))
    story.append(PageBreak())

    # =================================================================
    # SECTION 4: GLOSSARY
    # =================================================================
    story.append(P("4. Domain Glossary", "SectionHead"))

    gloss = [
        ["Term", "Abbr.", "Definition", "Category"],
        ["Trial Balance", "TB", "Report listing all GL account balances at a point in time", "balance_sheet"],
        ["General Ledger", "GL", "Master set of accounts summarizing all transactions", "balance_sheet"],
        ["FORTM Pack", "FORTM", "Financial Operations Review & Tracking Monthly", "regulatory"],
        ["PSGL", "--", "Primary Subledger/General Ledger master data system", "balance_sheet"],
        ["SC Bridge", "--", "System interface for TB data extraction from PSGL/S4", "general"],
        ["Finance Caption", "--", "High-level financial reporting category for GL accounts", "income_stmt"],
        ["EUC", "EUC", "End User Computing control for governed spreadsheets", "regulatory"],
        ["UK ACG", "ACG", "UK Automated Controls Governance framework", "regulatory"],
        ["FCA", "FCA", "Financial Conduct Authority; cutoff = submission deadline", "regulatory"],
        ["GFS", "GFS", "Global Financial Services organizational unit", "general"],
        ["Legal Entity", "LE", "Distinct legal organization; 234 LEs enterprise-wide", "general"],
        ["BSS RA", "BSS", "Business Support Services Risk Assessment", "regulatory"],
        ["Fast Close", "--", "Initiative to accelerate month-end timelines", "general"],
        ["M-3 to M+5", "--", "Working day offsets relative to month-end close", "general"],
        ["ABDO", "--", "Account-Branch-Dept-OperUnit concatenated composite key", "balance_sheet"],
    ]
    pgloss = []
    for i, row in enumerate(gloss):
        st = styles["TableHeader"] if i == 0 else styles["TableCell"]
        pgloss.append([Paragraph(c, st) for c in row])
    story.append(header_table(pgloss, [2.5*cm, 1.5*cm, 8.5*cm, 3*cm]))
    story.append(Spacer(1, 1*cm))

    # =================================================================
    # SECTION 5: RAG & DATA PRODUCT
    # =================================================================
    story.append(P("5. RAG &amp; Data Product Integration", "SectionHead"))

    story.append(P("RAG Pipeline", "SubHead"))
    rag = [
        ["Parameter", "Value"],
        ["Chunk size", "220 words"],
        ["Overlap", "40 words (step = 180)"],
        ["Total chunks", "55"],
        ["Embedding ID", "Deterministic UUID5"],
        ["Vector table", "TB_REVIEW_VECTORS"],
        ["Formats", "JSONL + CSV"],
    ]
    story.append(header_table(rag, [4*cm, 11.5*cm]))
    story.append(Spacer(1, 0.5*cm))

    story.append(P("ODPS 4.1 Data Product", "SubHead"))
    story.append(P(
        "Registered as <b>trial-balance-review-v1</b> in the HANA Training Data Product Catalog."
    ))
    story.append(bullet("<b>Security:</b> Confidential, vLLM-only routing, full audit"))
    story.append(bullet("<b>Country view:</b> HK with HKMA terminology and HKG entity filter"))
    story.append(bullet("<b>System prompt:</b> TB review assistant with 5 decision point references"))
    story.append(bullet("<b>RAG sources:</b> 55 chunks from extracted docs, requirements, and process specs"))
    story.append(bullet("<b>Schema:</b> Points to workbook schemas for field-level metadata"))
    story.append(bullet("<b>Audit fields:</b> All output records include audit_id, version, processed_at, source_hash"))
    story.append(PageBreak())

    # =================================================================
    # APPENDIX: FILE INVENTORY
    # =================================================================
    story.append(P("Appendix: File Inventory", "SectionHead"))

    files = [
        ["Path", "Layer", "Format"],
        ["extracted/business-case-trial-balance.md", "Extracted Text", "Markdown"],
        ["extracted/business-case-bss-risk-assessment.md", "Extracted Text", "Markdown"],
        ["extracted/doi-trial-balance-process.md", "Extracted Text", "Markdown"],
        ["extracted/bpmn-tb-review-glo.md", "Extracted Text", "Markdown"],
        ["extracted/bpmn-elements.json", "Extracted Text", "JSON"],
        ["extracted/doi-images/*", "Extracted Text", "EMF/PNG"],
        ["requirements/tb-business-requirements.yaml", "Requirements", "YAML"],
        ["requirements/bss-risk-assessment-requirements.yaml", "Requirements", "YAML"],
        ["requirements/tb-glossary.yaml", "Requirements", "YAML"],
        ["process/tb-review-workflow.yaml", "Process Spec", "YAML"],
        ["process/tb-review-decision-points.yaml", "Process Spec", "YAML"],
        ["process/tb-review-controls.yaml", "Process Spec", "YAML"],
        ["training-data/hkg-tb-schema.yaml", "Training Data", "YAML"],
        ["training-data/hkg-pl-schema.yaml", "Training Data", "YAML"],
        ["training-data/hkg-tb-sample.csv", "Training Data", "CSV"],
        ["training-data/hkg-pl-sample.csv", "Training Data", "CSV"],
        ["rag/rag_chunks.jsonl", "RAG Pipeline", "JSONL"],
        ["rag/rag_embedding_records.jsonl", "RAG Pipeline", "JSONL"],
        ["rag/rag_embedding_records.csv", "RAG Pipeline", "CSV"],
        ["rag/rag_manifest.json", "RAG Pipeline", "JSON"],
        ["data-product/trial-balance-review-v1.yaml", "App Integration", "YAML"],
        ["manifest.json", "Index", "JSON"],
    ]
    pfiles = []
    for i, row in enumerate(files):
        st = styles["TableHeader"] if i == 0 else styles["TableCell"]
        pfiles.append([Paragraph(c, st) for c in row])
    story.append(header_table(pfiles, [8*cm, 3.5*cm, 4*cm]))

    # Build
    doc.build(story)
    print(f"PDF generated: {OUTPUT}")


if __name__ == "__main__":
    build()
