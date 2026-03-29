//
//  SecurityScopedBookmarkStore.swift
//  TableScope
//
//

import Foundation

nonisolated struct SecurityScopedBookmarkStore {
    private struct StoredFolderBookmark: Codable, Equatable, Sendable {
        let folderPath: String
        let bookmarkData: Data
    }

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "TableScope.SecurityScopedFolderBookmarks"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func saveReadOnlyBookmark(for folderURL: URL) throws {
        let normalizedFolderURL = Self.normalizedDirectoryURL(folderURL)
        let bookmarkData = try normalizedFolderURL.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        var bookmarks = loadBookmarks()
        bookmarks.removeAll { $0.folderPath == normalizedFolderURL.path }
        bookmarks.append(
            StoredFolderBookmark(
                folderPath: normalizedFolderURL.path,
                bookmarkData: bookmarkData
            )
        )
        saveBookmarks(bookmarks)
    }

    func resolveStoredFolderScope(covering expectedFolderURL: URL) -> ActiveSecurityScope? {
        let normalizedExpectedFolderURL = Self.normalizedDirectoryURL(expectedFolderURL)
        var bookmarks = loadBookmarks()
        var didMutateBookmarks = false

        let sortedBookmarks = bookmarks.sorted {
            $0.folderPath.count > $1.folderPath.count
        }

        for bookmark in sortedBookmarks {
            guard let bookmarkIndex = bookmarks.firstIndex(of: bookmark) else {
                continue
            }

            do {
                var isStale = false
                let resolvedURL = try URL(
                    resolvingBookmarkData: bookmark.bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let normalizedResolvedURL = Self.normalizedDirectoryURL(resolvedURL)

                guard Self.isSameOrAncestor(normalizedResolvedURL, of: normalizedExpectedFolderURL) else {
                    continue
                }

                if isStale {
                    if let refreshedBookmarkData = try? normalizedResolvedURL.bookmarkData(
                        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        bookmarks[bookmarkIndex] = StoredFolderBookmark(
                            folderPath: normalizedResolvedURL.path,
                            bookmarkData: refreshedBookmarkData
                        )
                        didMutateBookmarks = true
                    }
                }

                let didStartAccess = normalizedResolvedURL.startAccessingSecurityScopedResource()
                guard didStartAccess else {
                    bookmarks.remove(at: bookmarkIndex)
                    didMutateBookmarks = true
                    continue
                }

                if didMutateBookmarks {
                    saveBookmarks(bookmarks)
                }

                return ActiveSecurityScope(
                    url: normalizedResolvedURL,
                    kind: .containingFolder,
                    startedAccess: didStartAccess
                )
            } catch {
                bookmarks.remove(at: bookmarkIndex)
                didMutateBookmarks = true
            }
        }

        if didMutateBookmarks {
            saveBookmarks(bookmarks)
        }

        return nil
    }

    func removeAllBookmarks() {
        defaults.removeObject(forKey: storageKey)
    }

    static func normalizedDirectoryURL(_ url: URL) -> URL {
        url
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    static func isSameOrAncestor(_ candidateFolderURL: URL, of expectedFolderURL: URL) -> Bool {
        let candidatePath = normalizedDirectoryURL(candidateFolderURL).path
        let expectedPath = normalizedDirectoryURL(expectedFolderURL).path

        return expectedPath == candidatePath || expectedPath.hasPrefix(candidatePath + "/")
    }

    private func loadBookmarks() -> [StoredFolderBookmark] {
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }

        return (try? PropertyListDecoder().decode([StoredFolderBookmark].self, from: data)) ?? []
    }

    private func saveBookmarks(_ bookmarks: [StoredFolderBookmark]) {
        let data = try? PropertyListEncoder().encode(bookmarks)
        defaults.set(data, forKey: storageKey)
    }
}
