import Foundation

nonisolated struct OutlookToolFolder: Codable, Sendable {
    let id: String
    let displayName: String
    let totalItemCount: Int?
    let unreadItemCount: Int?
    let childFolderCount: Int?
}

nonisolated struct OutlookToolFolderPage: Codable, Sendable {
    let value: [OutlookToolFolder]
}

nonisolated struct OutlookToolAttachment: Codable, Sendable {
    let id: String
    let name: String?
    let contentType: String?
    let size: Int?
    let isInline: Bool?
    let lastModifiedDateTime: String?
}

nonisolated struct OutlookToolAttachmentPage: Codable, Sendable {
    let value: [OutlookToolAttachment]
}

actor OutlookGraphToolClient {
    private let baseURL = URL(string: "https://graph.microsoft.com/v1.0")!
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func listFolders(accessToken: String, includeHidden: Bool = false) async throws -> [OutlookToolFolder] {
        var components = URLComponents(url: baseURL.appendingPathComponent("me/mailFolders"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "$select", value: "id,displayName,totalItemCount,unreadItemCount,childFolderCount"),
            URLQueryItem(name: "$top", value: "100"),
            URLQueryItem(name: "includeHiddenFolders", value: includeHidden ? "true" : "false")
        ]
        let page: OutlookToolFolderPage = try await get(components.url, accessToken: accessToken)
        return page.value
    }

    func listMessages(folderID: String?, pageSize: Int, unreadOnly: Bool, accessToken: String) async throws -> [GraphMailMessage] {
        let safeTop = String(min(max(pageSize, 1), 50))
        let path = folderID.flatMap { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "me/mailFolders/\($0)/messages" : nil } ?? "me/messages"
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "$select", value: messageSelectFields),
            URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
            URLQueryItem(name: "$top", value: safeTop)
        ]
        if unreadOnly {
            queryItems.append(URLQueryItem(name: "$filter", value: "isRead eq false"))
        }
        components.queryItems = queryItems
        let page: GraphMailPage = try await get(components.url, accessToken: accessToken)
        return page.value
    }

    func searchMessages(query: String, folderID: String?, pageSize: Int, accessToken: String) async throws -> [GraphMailMessage] {
        let safeQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeQuery.isEmpty else { return [] }
        let path = folderID.flatMap { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "me/mailFolders/\($0)/messages" : nil } ?? "me/messages"
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "$select", value: messageSelectFields),
            URLQueryItem(name: "$search", value: "\"\(safeQuery)\""),
            URLQueryItem(name: "$top", value: String(min(max(pageSize, 1), 50)))
        ]
        let page: GraphMailPage = try await get(components.url, accessToken: accessToken, extraHeaders: ["ConsistencyLevel": "eventual"])
        return page.value
    }

    func readMessage(messageID: String, accessToken: String) async throws -> GraphMailMessage {
        var components = URLComponents(url: baseURL.appendingPathComponent("me/messages").appendingPathComponent(messageID), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "$select", value: "\(messageSelectFields),body")]
        return try await get(components.url, accessToken: accessToken)
    }

    func listAttachments(messageID: String, accessToken: String) async throws -> [OutlookToolAttachment] {
        var components = URLComponents(url: baseURL.appendingPathComponent("me/messages").appendingPathComponent(messageID).appendingPathComponent("attachments"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "$select", value: "id,name,contentType,size,isInline,lastModifiedDateTime")]
        let page: OutlookToolAttachmentPage = try await get(components.url, accessToken: accessToken)
        return page.value
    }

    func markRead(messageID: String, isRead: Bool, accessToken: String) async throws -> GraphMailMessage {
        try await patchMessage(messageID: messageID, payload: ["isRead": isRead], accessToken: accessToken)
    }

    func moveMessage(messageID: String, destinationID: String, accessToken: String) async throws -> GraphMailMessage {
        var request = makeRequest(url: baseURL.appendingPathComponent("me/messages").appendingPathComponent(messageID).appendingPathComponent("move"), accessToken: accessToken)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["destinationId": destinationID])
        let (data, response) = try await session.data(for: request)
        try MicrosoftGraphMailClient.validate(response: response, data: data, allowedStatuses: 200...201)
        return try decoder.decode(GraphMailMessage.self, from: data)
    }

    func deleteMessage(messageID: String, accessToken: String) async throws {
        var request = makeRequest(url: baseURL.appendingPathComponent("me/messages").appendingPathComponent(messageID), accessToken: accessToken)
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try MicrosoftGraphMailClient.validate(response: response, data: data, allowedStatuses: 200...204)
    }

    func reply(messageID: String, comment: String, accessToken: String) async throws {
        try await messageAction(messageID: messageID, action: "reply", payload: ["comment": comment], accessToken: accessToken)
    }

    func replyAll(messageID: String, comment: String, accessToken: String) async throws {
        try await messageAction(messageID: messageID, action: "replyAll", payload: ["comment": comment], accessToken: accessToken)
    }

    func forward(messageID: String, comment: String, recipients: [String], accessToken: String) async throws {
        let payload: [String: Any] = [
            "comment": comment,
            "toRecipients": recipients.map { ["emailAddress": ["address": $0]] }
        ]
        try await messageAction(messageID: messageID, action: "forward", payload: payload, accessToken: accessToken)
    }

    func createDraft(subject: String, body: String, recipients: [String], accessToken: String) async throws -> GraphMailMessage {
        let client = MicrosoftGraphMailClient(session: session)
        return try await client.createDraft(subject: subject, htmlBody: body, to: recipients, accessToken: accessToken)
    }

    func sendMail(subject: String, body: String, recipients: [String], accessToken: String) async throws {
        let request = GraphSendMailRequest(
            message: GraphSendMailRequest.MailMessage(
                subject: subject,
                body: GraphSendMailRequest.Body(contentType: "HTML", content: body),
                toRecipients: recipients.map { GraphSendMailRequest.Recipient(emailAddress: .init(address: $0, name: nil)) },
                ccRecipients: nil,
                bccRecipients: nil,
                attachments: nil
            ),
            saveToSentItems: true
        )
        let client = MicrosoftGraphMailClient(session: session)
        try await client.sendMail(request, accessToken: accessToken)
    }

    private func patchMessage(messageID: String, payload: [String: Any], accessToken: String) async throws -> GraphMailMessage {
        var request = makeRequest(url: baseURL.appendingPathComponent("me/messages").appendingPathComponent(messageID), accessToken: accessToken)
        request.httpMethod = "PATCH"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        try MicrosoftGraphMailClient.validate(response: response, data: data, allowedStatuses: 200...200)
        return try decoder.decode(GraphMailMessage.self, from: data)
    }

    private func messageAction(messageID: String, action: String, payload: [String: Any], accessToken: String) async throws {
        var request = makeRequest(url: baseURL.appendingPathComponent("me/messages").appendingPathComponent(messageID).appendingPathComponent(action), accessToken: accessToken)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        try MicrosoftGraphMailClient.validate(response: response, data: data, allowedStatuses: 200...202)
    }

    private func get<T: Decodable>(_ url: URL?, accessToken: String, extraHeaders: [String: String] = [:]) async throws -> T {
        guard let url else { throw GraphHTTPError.missingURL }
        let request = makeRequest(url: url, accessToken: accessToken, extraHeaders: extraHeaders)
        let (data, response) = try await session.data(for: request)
        try MicrosoftGraphMailClient.validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func makeRequest(url: URL, accessToken: String, extraHeaders: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "client-request-id")
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return request
    }

    private var messageSelectFields: String {
        "id,subject,from,toRecipients,ccRecipients,receivedDateTime,sentDateTime,bodyPreview,isRead,hasAttachments"
    }
}

@MainActor
enum OutlookTools {
    private static let client = OutlookGraphToolClient()

    static func status() async -> String {
        do {
            let auth = MicrosoftGraphAuthManager()
            await auth.bootstrap()
            guard auth.isSignedIn else {
                return "Outlook is not signed in. Open Outlook in Lumen and sign in first."
            }
            let username = auth.account?.username ?? auth.account?.name ?? "Microsoft account"
            return "Outlook signed in as \(username). Auth provider: \(auth.authProviderDescription)."
        } catch {
            return "Outlook status failed: \(error.localizedDescription)"
        }
    }

    static func listFolders(args: [String: String]) async -> String {
        await perform(scopes: MicrosoftGraphScope.inboxRead) { token in
            let folders = try await client.listFolders(accessToken: token, includeHidden: bool(args["includeHidden"]))
            if folders.isEmpty { return "No Outlook mail folders found." }
            return folders.map { folder in
                "- \(folder.displayName) — id: \(folder.id), unread: \(folder.unreadItemCount ?? 0), total: \(folder.totalItemCount ?? 0)"
            }.joined(separator: "\n")
        }
    }

    static func listMessages(args: [String: String]) async -> String {
        await perform(scopes: MicrosoftGraphScope.inboxRead) { token in
            let messages = try await client.listMessages(
                folderID: folderID(from: args),
                pageSize: int(args["limit"] ?? args["top"], defaultValue: 10),
                unreadOnly: bool(args["unreadOnly"] ?? args["unread"]),
                accessToken: token
            )
            return formatMessages(messages, includeBody: false)
        }
    }

    static func searchMessages(args: [String: String]) async -> String {
        let query = args["query"] ?? args["q"] ?? args["search"] ?? ""
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Missing Outlook search query." }
        return await perform(scopes: MicrosoftGraphScope.inboxRead) { token in
            let messages = try await client.searchMessages(
                query: query,
                folderID: folderID(from: args),
                pageSize: int(args["limit"] ?? args["top"], defaultValue: 10),
                accessToken: token
            )
            return formatMessages(messages, includeBody: false)
        }
    }

    static func readMessage(args: [String: String]) async -> String {
        guard let id = messageID(from: args) else { return "Missing Outlook message id." }
        return await perform(scopes: MicrosoftGraphScope.inboxRead) { token in
            let message = try await client.readMessage(messageID: id, accessToken: token)
            return formatMessage(message, includeBody: true)
        }
    }

    static func listAttachments(args: [String: String]) async -> String {
        guard let id = messageID(from: args) else { return "Missing Outlook message id." }
        return await perform(scopes: MicrosoftGraphScope.inboxRead) { token in
            let attachments = try await client.listAttachments(messageID: id, accessToken: token)
            if attachments.isEmpty { return "No attachments found for message \(id)." }
            return attachments.map { attachment in
                "- \(attachment.name ?? "Unnamed attachment") — id: \(attachment.id), type: \(attachment.contentType ?? "unknown"), size: \(attachment.size ?? 0) bytes, inline: \(attachment.isInline ?? false)"
            }.joined(separator: "\n")
        }
    }

    static func createDraft(args: [String: String]) async -> String {
        let recipients = recipients(from: args)
        guard !recipients.isEmpty else { return "Missing Outlook draft recipient. Args: to, subject, body." }
        let subject = args["subject"] ?? ""
        let body = args["body"] ?? args["message"] ?? args["text"] ?? ""
        guard !subject.isEmpty || !body.isEmpty else { return "Missing Outlook draft subject/body." }
        return await perform(scopes: MicrosoftGraphScope.readWriteMail) { token in
            let draft = try await client.createDraft(subject: subject, body: body, recipients: recipients, accessToken: token)
            return "Created Outlook draft: \(draft.subject ?? "(No subject)")\nMessage id: \(draft.id)"
        }
    }

    static func sendMail(args: [String: String]) async -> String {
        let recipients = recipients(from: args)
        guard !recipients.isEmpty else { return "Missing Outlook send recipient. Args: to, subject, body." }
        let subject = args["subject"] ?? ""
        let body = args["body"] ?? args["message"] ?? args["text"] ?? ""
        guard !subject.isEmpty || !body.isEmpty else { return "Missing Outlook send subject/body." }
        return await perform(scopes: MicrosoftGraphScope.readWriteMail) { token in
            try await client.sendMail(subject: subject, body: body, recipients: recipients, accessToken: token)
            return "Sent Outlook email to \(recipients.joined(separator: ", "))."
        }
    }

    static func markRead(args: [String: String], isRead: Bool) async -> String {
        guard let id = messageID(from: args) else { return "Missing Outlook message id." }
        return await perform(scopes: MicrosoftGraphScope.readWriteMail) { token in
            let message = try await client.markRead(messageID: id, isRead: isRead, accessToken: token)
            return "Marked Outlook message as \(isRead ? "read" : "unread"): \(message.subject ?? id)"
        }
    }

    static func moveMessage(args: [String: String]) async -> String {
        guard let id = messageID(from: args) else { return "Missing Outlook message id." }
        let destination = args["destinationId"] ?? args["destination"] ?? args["folderId"] ?? args["folder"] ?? ""
        guard !destination.isEmpty else { return "Missing destination folder id/name. Use archive, deleteditems, junkemail, inbox, or a folder id." }
        return await perform(scopes: MicrosoftGraphScope.readWriteMail) { token in
            let moved = try await client.moveMessage(messageID: id, destinationID: canonicalFolderID(destination), accessToken: token)
            return "Moved Outlook message to \(destination). New message id: \(moved.id)"
        }
    }

    static func deleteMessage(args: [String: String]) async -> String {
        guard let id = messageID(from: args) else { return "Missing Outlook message id." }
        return await perform(scopes: MicrosoftGraphScope.readWriteMail) { token in
            try await client.deleteMessage(messageID: id, accessToken: token)
            return "Deleted Outlook message: \(id)"
        }
    }

    static func reply(args: [String: String], replyAll: Bool) async -> String {
        guard let id = messageID(from: args) else { return "Missing Outlook message id." }
        let comment = args["body"] ?? args["comment"] ?? args["message"] ?? args["text"] ?? ""
        guard !comment.isEmpty else { return "Missing reply body/comment." }
        return await perform(scopes: MicrosoftGraphScope.readWriteMail) { token in
            if replyAll { try await client.replyAll(messageID: id, comment: comment, accessToken: token) }
            else { try await client.reply(messageID: id, comment: comment, accessToken: token) }
            return replyAll ? "Sent Outlook reply-all." : "Sent Outlook reply."
        }
    }

    static func forward(args: [String: String]) async -> String {
        guard let id = messageID(from: args) else { return "Missing Outlook message id." }
        let to = recipients(from: args)
        guard !to.isEmpty else { return "Missing forward recipient." }
        let comment = args["body"] ?? args["comment"] ?? args["message"] ?? args["text"] ?? ""
        return await perform(scopes: MicrosoftGraphScope.readWriteMail) { token in
            try await client.forward(messageID: id, comment: comment, recipients: to, accessToken: token)
            return "Forwarded Outlook message to \(to.joined(separator: ", "))."
        }
    }

    private static func perform(scopes: [String], operation: @escaping @Sendable (String) async throws -> String) async -> String {
        do {
            let auth = MicrosoftGraphAuthManager()
            await auth.bootstrap()
            guard auth.isSignedIn else {
                return "Outlook is not signed in. Open Outlook in Lumen and sign in first."
            }
            let token = try await auth.acquireToken(scopes: scopes, preferredAccountID: auth.account?.id)
            return try await operation(token)
        } catch {
            return "Outlook tool failed: \(error.localizedDescription)"
        }
    }

    private static func formatMessages(_ messages: [GraphMailMessage], includeBody: Bool) -> String {
        if messages.isEmpty { return "No Outlook messages found." }
        return messages.map { formatMessage($0, includeBody: includeBody) }.joined(separator: "\n\n---\n\n")
    }

    private static func formatMessage(_ message: GraphMailMessage, includeBody: Bool) -> String {
        var lines = [
            "Subject: \(message.subject?.isEmpty == false ? message.subject! : "(No subject)")",
            "ID: \(message.id)",
            "From: \(message.senderLine)",
            "Received: \(message.receivedDateTime ?? "unknown")",
            "Unread: \((message.isRead ?? true) ? "false" : "true")",
            "Has attachments: \(message.hasAttachments ?? false)",
            "Preview: \(message.previewLine)"
        ]
        if includeBody, let body = message.body?.content, !body.isEmpty {
            lines.append("Body:\n\(body)")
        }
        return lines.joined(separator: "\n")
    }

    private static func recipients(from args: [String: String]) -> [String] {
        let raw = args["to"] ?? args["recipient"] ?? args["recipients"] ?? args["email"] ?? ""
        return raw.split { $0 == "," || $0 == ";" || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func messageID(from args: [String: String]) -> String? {
        let value = args["messageId"] ?? args["messageID"] ?? args["id"] ?? args["message"]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func folderID(from args: [String: String]) -> String? {
        let value = args["folderId"] ?? args["folderID"] ?? args["folder"]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return canonicalFolderID(trimmed)
    }

    private static func canonicalFolderID(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "archive", "archives": return "archive"
        case "deleted", "delete", "trash", "deleted items", "deleteditems": return "deleteditems"
        case "junk", "spam", "junk email", "junkemail": return "junkemail"
        case "sent", "sent items", "sentitems": return "sentitems"
        case "draft", "drafts": return "drafts"
        case "inbox": return "inbox"
        default: return raw
        }
    }

    private static func int(_ value: String?, defaultValue: Int) -> Int {
        guard let value, let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return defaultValue }
        return parsed
    }

    private static func bool(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "y", "on", "unread"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
