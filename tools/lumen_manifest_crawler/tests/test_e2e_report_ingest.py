from pathlib import Path

from lumen_manifest_crawler.dataset.runtime_ingest import load_runtime_audit_reports


E2E_REPORT = """E2E Test Report
Passed: 5
Failed: 2

Training signals for next run:
• response-quality: 2 issues
• Capture failed prompts + final outputs into next fine-tuning dataset.
• Prioritize scenarios with repeated tool-boundary violations.

✅ Training eval: weather stays grounded
Prompt: What is the weather here and should I carry an umbrella?
Intent: weather / expected weather
Final: I need location access, or a city name, to check the weather.

❌ Training eval: memory save/recall
Prompt: Remember that I prefer concise bullet points, then tell me what you remembered.
Intent: memory / expected memory
Failures: Required final hint missing: remember
Final: Saved: I prefer concise bullet points.

❌ Training eval: communication drafting
Prompt: Draft an email to Alex with a professional update and ask one clarifying question.
Intent: emailDraft / expected emailDraft
Failures: Required final hint missing: question
Final: emailDraft
"""


GENERIC_E2E_REPORT = """E2E Test Report
Passed: 0
Failed: 2

❌ Training eval: memory custom detail
Prompt: Remember that my shop supplier is Delta Parts, then tell me what you remembered.
Intent: memory / expected memory
Failures: Required final hint missing: remember
Final: Saved.

❌ Training eval: email custom detail
Prompt: Draft an email to Sam about the delayed shipment and ask one clarifying question.
Intent: emailDraft / expected emailDraft
Failures: Required final hint missing: question
Final: emailDraft
"""


FINAL_WITH_EMAIL_HEADERS_REPORT = """E2E Test Report
Passed: 0
Failed: 1

❌ Training eval: communication drafting
Prompt: Draft an email to Alex with a professional update and ask one clarifying question.
Intent: emailDraft / expected emailDraft
Failures: Required final hint missing: question
Final: Subject: Project update

Hi Alex,

Here is the update.

Question: should I send this today?
"""


FINAL_WITH_GENERIC_CAPITALIZED_LINES_REPORT = """E2E Test Report
Passed: 0
Failed: 1

❌ Training eval: communication drafting
Prompt: Draft an email to Alex with a professional update and ask one clarifying question.
Intent: emailDraft / expected emailDraft
Failures: Required final hint missing: question
Final: Subject: Project update

Note: this line is part of the email body.
Summary: progress is moving forward.
Question: should I send this today?
"""


def test_load_runtime_audit_reports_ingests_text_e2e_report(tmp_path: Path):
    report_path = tmp_path / "e2e-report.txt"
    report_path.write_text(E2E_REPORT, encoding="utf-8")

    reports = load_runtime_audit_reports([report_path])

    assert len(reports) == 1
    report = reports[0]
    assert report["_sourceFormat"] == "lumen_e2e_text_report"
    assert report["passed"] == 5
    assert report["failed"] == 2
    assert report["scenarioCount"] == 3
    assert "response-quality: 2 issues" in report["trainingSignals"]
    assert len(report["failures"]) == 2


def test_e2e_failures_become_repair_samples_with_corrected_outputs(tmp_path: Path):
    report_path = tmp_path / "e2e-report.md"
    report_path.write_text(E2E_REPORT, encoding="utf-8")

    failures = load_runtime_audit_reports([report_path])[0]["failures"]
    by_intent = {failure["e2eScenario"]["intent"]: failure for failure in failures}

    memory = by_intent["memory"]
    assert memory["type"] == "e2e_missing_required_final_hint_remember"
    assert memory["agent"] == "mouth"
    assert memory["sourceLayer"] == "e2eTextReport"
    assert memory["scenario"] == "Remember that I prefer concise bullet points, then tell me what you remembered."
    assert memory["actual"] == "Saved: I prefer concise bullet points."
    assert "remember" in memory["repairSample"]["correctedOutput"].casefold()
    assert memory["repairSample"]["curriculum"] == "grounded_response_quality"

    email = by_intent["emailDraft"]
    assert email["type"] == "e2e_missing_required_final_hint_question"
    assert email["agent"] == "mouth"
    assert "question" in email["repairSample"]["correctedOutput"].casefold()
    assert "Alex" in email["repairSample"]["correctedOutput"]
    assert email["repairSample"]["curriculum"] == "tool_boundary_response_quality"


def test_e2e_corrected_outputs_are_derived_from_prompt_not_fixed_templates(tmp_path: Path):
    report_path = tmp_path / "generic-e2e-report.txt"
    report_path.write_text(GENERIC_E2E_REPORT, encoding="utf-8")

    failures = load_runtime_audit_reports([report_path])[0]["failures"]
    by_intent = {failure["e2eScenario"]["intent"]: failure for failure in failures}

    memory_output = by_intent["memory"]["repairSample"]["correctedOutput"]
    assert "Delta Parts" in memory_output
    assert "concise bullet points" not in memory_output
    assert "remember" in memory_output.casefold()

    email_output = by_intent["emailDraft"]["repairSample"]["correctedOutput"]
    assert "Sam" in email_output
    assert "delayed shipment" in email_output
    assert "Alex" not in email_output
    assert "question" in email_output.casefold()


def test_final_multiline_field_preserves_email_subject_body_headers(tmp_path: Path):
    report_path = tmp_path / "email-final-report.log"
    report_path.write_text(FINAL_WITH_EMAIL_HEADERS_REPORT, encoding="utf-8")

    failure = load_runtime_audit_reports([report_path])[0]["failures"][0]
    actual = failure["actual"]

    assert "Subject: Project update" in actual
    assert "Hi Alex," in actual
    assert "Question: should I send this today?" in actual
    assert failure["repairSample"]["badOutput"] == actual


def test_final_multiline_field_preserves_generic_capitalized_body_lines(tmp_path: Path):
    report_path = tmp_path / "email-final-generic-headers.log"
    report_path.write_text(FINAL_WITH_GENERIC_CAPITALIZED_LINES_REPORT, encoding="utf-8")

    failure = load_runtime_audit_reports([report_path])[0]["failures"][0]
    actual = failure["actual"]

    assert "Subject: Project update" in actual
    assert "Note: this line is part of the email body." in actual
    assert "Summary: progress is moving forward." in actual
    assert "Question: should I send this today?" in actual
    assert failure["repairSample"]["badOutput"] == actual
