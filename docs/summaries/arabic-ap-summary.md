# Summary: Arabic AP Invoice Processing Specification
**Reference:** AP-ARABIC-2026-v1.2  
**Target Persona:** AP Clerk

## 1. Executive Vision
The Arabic AP domain addresses the high-volume, linguistically complex challenge of processing invoices across a heterogeneous regulatory landscape (Saudi Arabia, UAE, Egypt, Bahrain, Qatar, Oman, and Jordan). The goal is to move from manual spreadsheet-based intake to an AI-augmented pipeline that ensures 100% VAT compliance while maintaining high-fidelity Arabic-to-English data extraction.

## 2. Core Technical Architecture
The system is built as a multi-stage AI pipeline:
- **Intake & OCR:** Processes scanned PDFs and images using Tesseract 5.0 with a custom "Arabic-Context" post-processor to handle right-to-left layout drift.
- **Translation Gate:** A critical quality gate that translates extracted Arabic fields into English canonical structures.
- **Multi-Country VAT Engine:** A modular rules-engine that validates invoices against ZATCA (Saudi), FTA (UAE), and NBR (Bahrain) requirements.
- **Workflow Engine:** Realizes two distinct state machines—`po-eproc` (PO-backed) and `direct-ap` (Non-PO)—to manage the invoice lifecycle.

## 3. Failure Mode & Operational Safety
A world-class FMEA (Failure Mode and Effects Analysis) identifies risks like **OCR Character Drift** (e.g., misreading '5' as '6') and specifies technical mitigations such as cross-field arithmetic validation (Net + VAT == Gross). 

**Human-in-the-Loop (HITL) Gate:** No invoice marked as `HOLD` by the VAT engine can be released without a human persona's cryptographic sign-off.

## 4. Implementation Manifest
- **Wave 1:** Implement Invoice Intake & OCR Gateway.
- **Wave 2:** Implement the Multi-Country VAT Engine (Saudi, UAE, Bahrain, Oman).
- **Wave 3:** Deliver the Arabic/English Translation Calibration Pilot.

## 5. Governance & Dependencies
This domain is wrapped by the **Regulations Specification** at runtime, ensuring that every tool call carries a mandatory Identity Attribution envelope. It depends on the **Simula Domain** for the synthetic training corpus used to calibrate its OCR and extraction models.

---
*End of Summary.*
