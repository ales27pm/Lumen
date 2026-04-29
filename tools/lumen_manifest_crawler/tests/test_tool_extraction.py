from pathlib import Path

from lumen_manifest_crawler.manifest import AgentBehaviorManifest
from lumen_manifest_crawler.swift_extractors.base import SwiftFile
from lumen_manifest_crawler.swift_extractors.tool_definition import ToolDefinitionExtractor


def test_tool_definition_extraction():
    text = '''
    struct ToolRegistry {
      static let all: [ToolDefinition] = [
        ToolDefinition(
          id: "calendar.create",
          displayName: "Create Calendar Event",
          description: "Creates a calendar event.",
          requiresApproval: true,
          permissionKey: "NSCalendarsFullAccessUsageDescription",
          arguments: [
            ToolArgument(name: "title", type: .string, required: true),
            ToolArgument(name: "startsInMinutes", type: .double, required: true)
          ]
        )
      ]
    }
    '''
    manifest = AgentBehaviorManifest()
    ToolDefinitionExtractor().extract(SwiftFile(Path("ToolDefinition.swift"), "ToolDefinition.swift", text), manifest)
    assert len(manifest.tools) == 1
    tool = manifest.tools[0]
    assert tool.id == "calendar.create"
    assert tool.requiresApproval is True
    assert tool.permissionKey == "NSCalendarsFullAccessUsageDescription"
    assert {arg.name for arg in tool.arguments} == {"title", "startsInMinutes"}
