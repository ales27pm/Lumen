from lumen_manifest_crawler.manifest import AgentBehaviorManifest, IntentManifest, ToolArgumentManifest, ToolManifest
from lumen_manifest_crawler.validators import validate_manifest


def test_duplicate_tool_id_failure():
    manifest = AgentBehaviorManifest(tools=[ToolManifest(id="web.search"), ToolManifest(id="web.search")])
    report = validate_manifest(manifest)
    assert not report.passed
    assert any(f.code == "duplicate_tool_id" for f in report.failures)


def test_unknown_intent_tool_failure():
    manifest = AgentBehaviorManifest(intents=[IntentManifest(id="search", allowedToolIDs=["web.search"])])
    report = validate_manifest(manifest)
    assert not report.passed
    assert any(f.code == "unknown_intent_tool" for f in report.failures)


def test_unsupported_argument_type_failure():
    manifest = AgentBehaviorManifest(
        tools=[ToolManifest(id="x.run", arguments=[ToolArgumentManifest(name="payload", type="binary", required=True)])]
    )
    report = validate_manifest(manifest)
    assert not report.passed
    assert any(f.code == "unsupported_argument_type" for f in report.failures)
