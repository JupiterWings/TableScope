//
//  WALFolderAccessTests.swift
//  TableScopeTests
//
//

import XCTest
@testable import TableScope

final class WALFolderAccessTests: XCTestCase {
    private var bookmarkDefaultsSuiteName: String!
    private var bookmarkDefaults: UserDefaults!
    private var bookmarkStore: SecurityScopedBookmarkStore!

    override func setUp() {
        super.setUp()

        let suiteName = "TableScopeTests.\(UUID().uuidString)"
        bookmarkDefaultsSuiteName = suiteName
        bookmarkDefaults = UserDefaults(suiteName: suiteName)
        bookmarkDefaults.removePersistentDomain(forName: suiteName)
        bookmarkStore = SecurityScopedBookmarkStore(
            defaults: bookmarkDefaults,
            storageKey: "WALFolderAccessTests.Bookmarks"
        )
    }

    override func tearDown() {
        bookmarkStore.removeAllBookmarks()
        bookmarkDefaults.removePersistentDomain(forName: bookmarkDefaultsSuiteName)
        bookmarkDefaultsSuiteName = nil
        bookmarkDefaults = nil
        bookmarkStore = nil
        super.tearDown()
    }

    func testStandaloneDatabaseOpenDoesNotEnterFolderAuthorizationFlow() async throws {
        let appState = await MainActor.run {
            AppState(bookmarkStore: bookmarkStore)
        }
        let databaseURL = try copiedFixture(named: "Sample", extension: "sqlite3")

        await appState.presentOpenPanel()
        await appState.handleImporterResult(result: .success([databaseURL]))

        let sessions = await MainActor.run { appState.sessions }
        let pendingDatabaseOpen = await MainActor.run { appState.pendingDatabaseOpen }

        XCTAssertEqual(sessions.count, 1)
        XCTAssertNil(pendingDatabaseOpen)
    }

    func testWALDatabasePromptsForFolderThenRetriesOpen() async throws {
        let appState = await MainActor.run {
            AppState(bookmarkStore: bookmarkStore)
        }
        let databaseURL = try copiedFixture(named: "Sample", extension: "sqlite3")
        try createCompanionSidecars(for: databaseURL)

        await appState.presentOpenPanel()
        await appState.handleImporterResult(result: .success([databaseURL]))

        let pendingBeforeFolderGrant = await MainActor.run { appState.pendingDatabaseOpen }
        let isPresentingImporter = await MainActor.run { appState.isPresentingImporter }
        XCTAssertNotNil(pendingBeforeFolderGrant)
        XCTAssertTrue(isPresentingImporter)

        await appState.handleImporterResult(result: .success([databaseURL.deletingLastPathComponent()]))

        let sessions = await MainActor.run { appState.sessions }
        let pendingAfterFolderGrant = await MainActor.run { appState.pendingDatabaseOpen }

        XCTAssertEqual(sessions.count, 1)
        XCTAssertNil(pendingAfterFolderGrant)
    }

    func testRequiresFolderAuthorizationDetectsCompanionFiles() async throws {
        let appState = await MainActor.run {
            AppState(bookmarkStore: bookmarkStore)
        }
        let databaseURL = try copiedFixture(named: "Sample", extension: "sqlite3")

        let requiresBeforeSidecars = await MainActor.run {
            appState.requiresFolderAuthorization(for: databaseURL)
        }
        XCTAssertFalse(requiresBeforeSidecars)

        try createCompanionSidecars(for: databaseURL)

        let requiresAfterSidecars = await MainActor.run {
            appState.requiresFolderAuthorization(for: databaseURL)
        }
        XCTAssertTrue(requiresAfterSidecars)
    }

    func testWrongFolderSelectionIsRejectedAndKeepsPendingOpen() async throws {
        let appState = await MainActor.run {
            AppState(bookmarkStore: bookmarkStore)
        }
        let databaseURL = try copiedFixture(named: "Sample", extension: "sqlite3")
        try createCompanionSidecars(for: databaseURL)
        let unrelatedFolderURL = try temporaryDirectory(named: "Unrelated")

        await appState.presentOpenPanel()
        await appState.handleImporterResult(result: .success([databaseURL]))
        await appState.handleImporterResult(result: .success([unrelatedFolderURL]))

        let pendingDatabaseOpen = await MainActor.run { appState.pendingDatabaseOpen }
        let alert = await MainActor.run { appState.alert }
        let sessions = await MainActor.run { appState.sessions }

        XCTAssertNotNil(pendingDatabaseOpen)
        XCTAssertEqual(alert?.title, "Wrong Folder Selected")
        XCTAssertTrue(sessions.isEmpty)
    }

    func testStoredBookmarkResolvesAncestorFolder() throws {
        let rootFolderURL = try temporaryDirectory(named: "BookmarkRoot")
        let nestedFolderURL = rootFolderURL
            .appendingPathComponent("Deep")
            .appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nestedFolderURL, withIntermediateDirectories: true)

        try bookmarkStore.saveReadOnlyBookmark(for: rootFolderURL)
        let resolvedScope = bookmarkStore.resolveStoredFolderScope(covering: nestedFolderURL)

        XCTAssertNotNil(resolvedScope)
        XCTAssertEqual(resolvedScope?.kind, .containingFolder)
        XCTAssertTrue(
            SecurityScopedBookmarkStore.isSameOrAncestor(
                resolvedScope?.url ?? rootFolderURL,
                of: nestedFolderURL
            )
        )

        if let resolvedScope, resolvedScope.startedAccess {
            resolvedScope.url.stopAccessingSecurityScopedResource()
        }
    }

    func testFolderCancellationClearsPendingOpenAfterAlertDismiss() async throws {
        let appState = await MainActor.run {
            AppState(bookmarkStore: bookmarkStore)
        }
        let databaseURL = try copiedFixture(named: "Sample", extension: "sqlite3")
        try createCompanionSidecars(for: databaseURL)

        await appState.presentOpenPanel()
        await appState.handleImporterResult(result: .success([databaseURL]))
        await MainActor.run {
            appState.handleImporterCancellation()
            appState.clearAlert()
        }

        let pendingDatabaseOpen = await MainActor.run { appState.pendingDatabaseOpen }
        XCTAssertNil(pendingDatabaseOpen)
    }

    private func copiedFixture(named name: String, extension fileExtension: String) throws -> URL {
        let sourceURL = try fixtureURL(named: name, extension: fileExtension)
        let destinationDirectoryURL = try temporaryDirectory(named: UUID().uuidString)
        let destinationURL = destinationDirectoryURL.appendingPathComponent("\(name).\(fileExtension)")

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TableScopeTests")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func createCompanionSidecars(for databaseURL: URL) throws {
        FileManager.default.createFile(atPath: databaseURL.path + "-wal", contents: Data())
        FileManager.default.createFile(atPath: databaseURL.path + "-shm", contents: Data())
    }

    private func fixtureURL(named name: String, extension fileExtension: String) throws -> URL {
        let bundle = Bundle(for: Self.self)

        if let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: fileExtension) {
            return url
        }

        throw XCTSkip("Missing fixture \(name).\(fileExtension)")
    }
}
