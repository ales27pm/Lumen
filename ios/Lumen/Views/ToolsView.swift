import SwiftUI

struct ToolsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 22) {
                        headerRow
                        ForEach(ToolCategory.allCases, id: \.self) { category in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(category.rawValue)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .padding(.leading, 2)
                                VStack(spacing: 0) {
                                    let tools = ToolRegistry.all.filter { $0.category == category }
                                    ForEach(Array(tools.enumerated()), id: \.element.id) { idx, tool in
                                        ToolToggleRow(tool: tool,
                                                      isEnabled: appState.enabledToolIDs.contains(tool.id)) {
                                            appState.toggleTool(tool.id)
                                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                        }
                                        if idx < tools.count - 1 {
                                            Divider().background(Theme.border).padding(.leading, 44)
                                        }
                                    }
                                }
                                .background(Theme.surface)
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Theme.border, lineWidth: 1)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Tools")
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(appState.enabledToolIDs.count) tools enabled")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                Text("The agent picks tools as needed")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }
}

struct ToolToggleRow: View {
    let tool: ToolDefinition
    let isEnabled: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tool.icon)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tool.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    if tool.requiresApproval {
                        Image(systemName: "lock")
                            .font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(tool.description).font(.caption).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isEnabled }, set: { _ in onToggle() }))
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
