import Foundation
import OSLog

@MainActor
final class SlotModelRuntimeCoordinator {
    static let shared = SlotModelRuntimeCoordinator()

    private let logger = Logger(subsystem: "ai.lumen.app", category: "slot-runtime")
    private var assignments: [LumenModelSlot: LumenModelAssignment] = [:]
    private var contextSize: Int = 2048
    private var preferExclusiveChatRuntime = true

    private init() {}

    func configure(
        assignments: [LumenModelSlot: LumenModelAssignment],
        contextSize: Int,
        preferExclusiveChatRuntime: Bool
    ) {
        self.assignments = assignments.filter { slot, assignment in
            slot != .embedding && FileManager.default.fileExists(atPath: assignment.localPath)
        }
        self.contextSize = max(512, contextSize)
        self.preferExclusiveChatRuntime = preferExclusiveChatRuntime
    }

    func assignment(for slot: LumenModelSlot) -> LumenModelAssignment? {
        assignments[slot]
    }

    var configuredAssignments: [LumenModelSlot: LumenModelAssignment] {
        assignments
    }

    func ensureReady(slot: LumenModelSlot) async throws {
        guard slot != .embedding else { return }
        guard let assignment = assignments[slot] else {
            throw LlamaError.slotModelNotLoaded("\(slot.rawValue): no assigned model")
        }
        guard FileManager.default.fileExists(atPath: assignment.localPath) else {
            throw LlamaError.modelFileNotFound(assignment.localPath)
        }

        if assignment.usesRoleAdapter || assignment.modelFamily == .qwen3 {
            try await ensureAdapterRuntimeReady(slot: slot, assignment: assignment)
            return
        }

        try await ensureLegacyRuntimeReady(slot: slot, assignment: assignment)
    }

    private func ensureAdapterRuntimeReady(slot: LumenModelSlot, assignment: LumenModelAssignment) async throws {
        if await AppLlamaService.shared.loadedChatPath != assignment.localPath {
            do {
                try await AppLlamaService.shared.loadSharedChatModel(path: assignment.localPath, contextSize: contextSize)
            } catch {
                logger.error("shared_base_load_failed slot=\(slot.rawValue, privacy: .public) path=\(assignment.localPath, privacy: .public) context=\(self.contextSize, privacy: .public) error=\(String(describing: error), privacy: .public)")
                if contextSize > 2048 {
                    try await AppLlamaService.shared.loadSharedChatModel(path: assignment.localPath, contextSize: 2048)
                } else {
                    throw error
                }
            }
        }

        guard let adapterPath = assignment.adapterPath else {
            await AppLlamaService.shared.clearActiveRoleAdapter()
            return
        }
        guard FileManager.default.fileExists(atPath: adapterPath) else {
            logger.error("role_adapter_missing slot=\(slot.rawValue, privacy: .public) path=\(adapterPath, privacy: .public)")
            await AppLlamaService.shared.clearActiveRoleAdapter()
            return
        }

        do {
            try await AppLlamaService.shared.loadRoleAdapter(slot: slot, path: adapterPath, scale: assignment.adapterScale)
            try await AppLlamaService.shared.activateRoleAdapter(slot: slot)
        } catch {
            logger.error("role_adapter_activation_failed slot=\(slot.rawValue, privacy: .public) path=\(adapterPath, privacy: .public) error=\(String(describing: error), privacy: .public)")
            await AppLlamaService.shared.unloadRoleAdapter(slot: slot)
        }
    }

    private func ensureLegacyRuntimeReady(slot: LumenModelSlot, assignment: LumenModelAssignment) async throws {
        if await AppLlamaService.shared.loadedChatPath(for: slot) == assignment.localPath {
            return
        }

        if preferExclusiveChatRuntime {
            await AppLlamaService.shared.unloadAllChat()
        } else {
            await AppLlamaService.shared.unloadChat(for: slot)
        }

        do {
            try await AppLlamaService.shared.loadChatModel(
                path: assignment.localPath,
                for: slot,
                contextSize: contextSize
            )
        } catch {
            logger.error("slot_model_load_failed slot=\(slot.rawValue, privacy: .public) path=\(assignment.localPath, privacy: .public) context=\(self.contextSize, privacy: .public) error=\(String(describing: error), privacy: .public)")
            if contextSize > 2048 {
                await AppLlamaService.shared.unloadAllChat()
                try await AppLlamaService.shared.loadChatModel(
                    path: assignment.localPath,
                    for: slot,
                    contextSize: 2048
                )
            } else {
                throw error
            }
        }
    }

    func ensurePrimaryReady(preferredSlots: [LumenModelSlot] = [.mouth, .cortex]) async -> Bool {
        for slot in preferredSlots {
            guard assignments[slot] != nil else { continue }
            do {
                try await ensureReady(slot: slot)
                return true
            } catch {
                logger.error("primary_slot_ready_failed slot=\(slot.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
                continue
            }
        }
        return false
    }
}
