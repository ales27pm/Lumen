import SwiftUI

struct FleetStatusCard: View {
    let snapshot: LumenModelFleetSnapshot
    let progresses: [String: DownloadProgress]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: snapshot.isRunnableV0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(snapshot.isRunnableV0 ? Theme.accent : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fleet v0")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }

            VStack(spacing: 8) {
                ForEach(LumenModelSlot.allCases) { slot in
                    HStack(spacing: 10) {
                        Text(slot.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 76, alignment: .leading)

                        if let assignment = snapshot.assignment(for: slot) {
                            Text("\(assignment.displayName) · \(assignment.parameters) · \(assignment.quantization)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        } else {
                            Text("missing")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(Theme.surfaceHigh.opacity(0.55))
                    .clipShape(.rect(cornerRadius: 8))
                }
            }

            let active = activeDownloads
            if !active.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloads")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    ForEach(active, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.name)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(Int(item.progress.fractionCompleted * 100))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            ProgressView(value: item.progress.fractionCompleted)
                                .tint(Theme.accent)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }

    private var summaryText: String {
        if snapshot.missingSlots.isEmpty { return "All logical slots are assigned." }
        return "Missing: \(snapshot.missingSlots.map(\.displayName).joined(separator: ", "))"
    }

    private var activeDownloads: [(id: String, name: String, progress: DownloadProgress)] {
        LumenModelFleetCatalog.v0Recommended.compactMap { model in
            guard let progress = progresses[model.id] else { return nil }
            switch progress.state {
            case .downloading, .paused:
                return (model.id, model.name, progress)
            case .queued, .completed, .failed:
                return nil
            }
        }
    }
}
