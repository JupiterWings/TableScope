//
//  DatabaseSource.swift
//  TableScope
//
//

import Foundation

nonisolated struct LocalFileDatabaseSource: Hashable, Sendable {
    let url: URL

    nonisolated var normalized: Self {
        Self(url: url.resolvingSymlinksInPath().standardizedFileURL)
    }

    nonisolated var displayName: String {
        normalized.url.lastPathComponent
    }

    nonisolated var parentPath: String {
        let path = normalized.url.deletingLastPathComponent().path
        return path.isEmpty ? "/" : path
    }
}

nonisolated struct RemoteDatabaseSource: Hashable, Sendable {
    let hostAlias: String
    let databasePath: String

    nonisolated var normalized: Self {
        let trimmedHostAlias = hostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = databasePath.trimmingCharacters(in: .whitespacesAndNewlines)

        return Self(
            hostAlias: trimmedHostAlias,
            databasePath: Self.normalizeRemotePath(trimmedPath)
        )
    }

    nonisolated var displayName: String {
        let path = normalized.databasePath
        let lastPathComponent = NSString(string: path).lastPathComponent
        return lastPathComponent.isEmpty ? path : lastPathComponent
    }

    nonisolated var parentPath: String {
        let normalizedSource = normalized
        let rawParentPath = NSString(string: normalizedSource.databasePath).deletingLastPathComponent
        let displayParentPath = rawParentPath.isEmpty ? "/" : rawParentPath
        return "\(normalizedSource.hostAlias):\(displayParentPath)"
    }

    nonisolated private static func normalizeRemotePath(_ rawPath: String) -> String {
        guard !rawPath.isEmpty else {
            return rawPath
        }

        let prefix: String
        let remainder: String

        if rawPath.hasPrefix("/") {
            prefix = "/"
            remainder = String(rawPath.drop(while: { $0 == "/" }))
        } else if rawPath.hasPrefix("~") {
            if let slashIndex = rawPath.firstIndex(of: "/") {
                prefix = String(rawPath[..<slashIndex])
                remainder = String(rawPath[rawPath.index(after: slashIndex)...])
            } else {
                return rawPath
            }
        } else {
            prefix = ""
            remainder = rawPath
        }

        var components: [String] = []
        for component in remainder.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let lastComponent = components.last, lastComponent != ".." {
                    components.removeLast()
                } else if prefix.isEmpty {
                    components.append(String(component))
                }
            default:
                components.append(String(component))
            }
        }

        switch prefix {
        case "/":
            return "/" + components.joined(separator: "/")
        case "":
            return components.isEmpty ? rawPath : components.joined(separator: "/")
        default:
            return components.isEmpty ? prefix : prefix + "/" + components.joined(separator: "/")
        }
    }
}

nonisolated enum DatabaseSource: Hashable, Sendable {
    case localFile(LocalFileDatabaseSource)
    case remoteSQLite(RemoteDatabaseSource)

    nonisolated var normalized: Self {
        switch self {
        case .localFile(let source):
            return .localFile(source.normalized)
        case .remoteSQLite(let source):
            return .remoteSQLite(source.normalized)
        }
    }

    nonisolated var displayName: String {
        switch self {
        case .localFile(let source):
            return source.displayName
        case .remoteSQLite(let source):
            return source.displayName
        }
    }

    nonisolated var parentPath: String {
        switch self {
        case .localFile(let source):
            return source.parentPath
        case .remoteSQLite(let source):
            return source.parentPath
        }
    }

    nonisolated var remoteSource: RemoteDatabaseSource? {
        guard case .remoteSQLite(let source) = self else {
            return nil
        }

        return source
    }

    nonisolated var localFileURL: URL? {
        guard case .localFile(let source) = self else {
            return nil
        }

        return source.url
    }

    nonisolated var isRemote: Bool {
        remoteSource != nil
    }
}

nonisolated struct RemoteDatabaseDraft: Sendable {
    var hostAlias = RemoteHelperConfiguration.defaultHostAlias
    var databasePath = ""
}
