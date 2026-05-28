import Foundation

actor LegacyGroundingCache {
    struct Key: Hashable { let conversationID: UUID?; let turnID: UUID?; let userHash: Int; let background: Bool }
    private struct Entry { let bundle: LegacyGroundingBundle; let expiresAt: Date }
    private var store: [Key: Entry] = [:]
    private let ttl: TimeInterval
    init(ttl: TimeInterval = 120) { self.ttl = ttl }

    func get(_ key: Key, now: Date = Date()) -> LegacyGroundingBundle? {
        guard let e = store[key], e.expiresAt > now else { store.removeValue(forKey: key); return nil }
        return e.bundle
    }
    func put(_ key: Key, bundle: LegacyGroundingBundle, now: Date = Date()) { store[key] = Entry(bundle: bundle, expiresAt: now.addingTimeInterval(ttl)) }
    func invalidate(conversationID: UUID?) { store = store.filter { $0.key.conversationID != conversationID } }
}
