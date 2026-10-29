import Foundation

enum ZoteroLookupError: Error, LocalizedError, Equatable {
    case unavailable
    case ambiguous([LiteratureZoteroIdentity])
    case noMatch
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法连接 Zotero 本地 API，请检查 Zotero 是否运行及本地 API 是否启用。"
        case .ambiguous: return "多个 Zotero 附件指向此文件，需要选择文献归属。"
        case .noMatch: return "没有找到与当前文件路径完全匹配的 Zotero 附件。"
        case .invalidResponse: return "Zotero 本地 API 返回的数据无效。"
        }
    }
}

/// Local API only. A filename is merely a candidate; its resolved attachment
/// path must match the open document before it can be linked.
enum ZoteroLocalLookup {
    private struct Item: Decodable {
        struct Creator: Decodable {
            var firstName: String?
            var lastName: String?
            var name: String?
        }
        struct Fields: Decodable {
            var key: String
            var itemType: String?
            var parentItem: String?
            var filename: String?
            var title: String?
            var date: String?
            var publicationTitle: String?
            var creators: [Creator]?

            private enum CodingKeys: String, CodingKey { case key, itemType, parentItem, filename, title, date, creators, publicationTitle }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                key = try values.decode(String.self, forKey: .key)
                itemType = try? values.decode(String.self, forKey: .itemType)
                // Zotero represents the parent of standalone attachments as false.
                parentItem = try? values.decode(String.self, forKey: .parentItem)
                filename = try? values.decode(String.self, forKey: .filename)
                title = try? values.decode(String.self, forKey: .title)
                date = try? values.decode(String.self, forKey: .date)
                publicationTitle = try? values.decode(String.self, forKey: .publicationTitle)
                creators = try? values.decode([Creator].self, forKey: .creators)
            }
        }
        var data: Fields
    }
    private struct Group: Decodable { var id: Int }

    private static func api(_ path: String, session: URLSession) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:23119/api/" + path) else { throw ZoteroLookupError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw ZoteroLookupError.unavailable
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 50_000_000 else {
            throw ZoteroLookupError.unavailable
        }
        return data
    }

    private static func metadata(parent: Item.Fields, library: String, attachmentKey: String, fallback: String) -> LiteratureZoteroIdentity {
        let authors = (parent.creators ?? []).map { creator in
            creator.name ?? [creator.firstName, creator.lastName].compactMap { $0 }.joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: ", ")
        let title = parent.title.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return LiteratureZoteroIdentity(library: library, itemKey: parent.key, attachmentKey: attachmentKey,
                                       title: title, authors: authors, year: parent.date ?? "", journal: parent.publicationTitle)
    }

    static func resolve(documentURL: URL) async throws -> LiteratureZoteroIdentity {
        let configuration = URLSessionConfiguration.ephemeral
        // A local library can contain thousands of attachments. The exhaustive
        // path check is intentionally bounded but needs longer than a small
        // single-item request; it runs off the reading path.
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let decoder = JSONDecoder()
        let groupData = try await api("users/0/groups", session: session)
        guard let groups = try? decoder.decode([Group].self, from: groupData) else { throw ZoteroLookupError.invalidResponse }
        let scopes = ["users/0"] + groups.map { "groups/\($0.id)" }
        let expected = documentURL.standardizedFileURL.resolvingSymlinksInPath()
        let component = expected.deletingLastPathComponent().lastPathComponent
        let keyPattern = try NSRegularExpression(pattern: "^[A-Z0-9]{8}$")
        let isKey = keyPattern.firstMatch(in: component, range: NSRange(component.startIndex..., in: component)) != nil
        var candidates: [(String, Item.Fields)] = []
        for scope in scopes {
            if isKey, let data = try? await api("\(scope)/items/\(component)", session: session),
               let item = try? decoder.decode(Item.self, from: data), item.data.itemType == "attachment" {
                candidates.append((scope, item.data))
                continue
            }
            var offset = 0
            while true {
                let data = try await api("\(scope)/items?itemType=attachment&format=json&limit=100&start=\(offset)", session: session)
                guard let items = try? decoder.decode([Item].self, from: data) else { throw ZoteroLookupError.invalidResponse }
                candidates.append(contentsOf: items.compactMap { item in
                    item.data.filename == expected.lastPathComponent ? (scope, item.data) : nil
                })
                if items.count < 100 { break }
                offset += items.count
                guard offset <= 100_000 else { throw ZoteroLookupError.invalidResponse }
                try Task.checkCancellation()
            }
        }
        var matches: [(String, Item.Fields)] = []
        for candidate in candidates {
            guard let data = try? await api("\(candidate.0)/items/\(candidate.1.key)/file/view/url", session: session),
                  let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: raw), url.isFileURL,
                  url.standardizedFileURL.resolvingSymlinksInPath() == expected else { continue }
            matches.append(candidate)
        }
        if matches.count > 1 {
            var choices: [LiteratureZoteroIdentity] = []
            for (scope, attachment) in matches {
                let parentKey = attachment.parentItem ?? attachment.key
                let data = try await api("\(scope)/items/\(parentKey)", session: session)
                guard let parent = try? decoder.decode(Item.self, from: data) else { throw ZoteroLookupError.invalidResponse }
                choices.append(metadata(parent: parent.data, library: scope == "users/0" ? "library" : scope,
                                        attachmentKey: attachment.key, fallback: expected.deletingPathExtension().lastPathComponent))
            }
            throw ZoteroLookupError.ambiguous(choices)
        }
        guard let (scope, attachment) = matches.first else { throw ZoteroLookupError.noMatch }
        let parentKey = attachment.parentItem ?? attachment.key
        let data = try await api("\(scope)/items/\(parentKey)", session: session)
        guard let parent = try? decoder.decode(Item.self, from: data) else { throw ZoteroLookupError.invalidResponse }
        let library = scope == "users/0" ? "library" : scope
        return metadata(parent: parent.data, library: library, attachmentKey: attachment.key,
                        fallback: expected.deletingPathExtension().lastPathComponent)
    }

    static func refresh(_ identity: LiteratureZoteroIdentity, documentURL: URL) async throws -> LiteratureZoteroIdentity {
        let valid = try NSRegularExpression(pattern: #"^(library|groups/[0-9]+)$"#)
        guard valid.firstMatch(in: identity.library, range: NSRange(identity.library.startIndex..., in: identity.library)) != nil,
              identity.itemKey.range(of: #"^[A-Z0-9]{8}$"#, options: .regularExpression) != nil,
              identity.attachmentKey.range(of: #"^[A-Z0-9]{8}$"#, options: .regularExpression) != nil else {
            throw ZoteroLookupError.invalidResponse
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let scope = identity.library == "library" ? "users/0" : identity.library
        let decoder = JSONDecoder()
        let attachmentData = try await api("\(scope)/items/\(identity.attachmentKey)", session: session)
        guard let attachment = try? decoder.decode(Item.self, from: attachmentData),
              (attachment.data.parentItem ?? attachment.data.key) == identity.itemKey else { throw ZoteroLookupError.noMatch }
        let pathData = try await api("\(scope)/items/\(identity.attachmentKey)/file/view/url", session: session)
        guard let raw = String(data: pathData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let path = URL(string: raw), path.isFileURL,
              path.standardizedFileURL.resolvingSymlinksInPath().path == documentURL.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw ZoteroLookupError.noMatch
        }
        let parentData = try await api("\(scope)/items/\(identity.itemKey)", session: session)
        guard let parent = try? decoder.decode(Item.self, from: parentData) else { throw ZoteroLookupError.invalidResponse }
        return metadata(parent: parent.data, library: identity.library, attachmentKey: identity.attachmentKey, fallback: identity.title)
    }
}
