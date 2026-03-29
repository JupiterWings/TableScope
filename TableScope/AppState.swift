//
//  AppState.swift
//  TableScope
//
//

import Foundation
import Observation
import UniformTypeIdentifiers

nonisolated enum ImporterMode: Sendable {
    case databaseFiles
    case folderForPendingDatabase

    var allowedContentTypes: [UTType] {
        switch self {
        case .databaseFiles:
            return [.data]
        case .folderForPendingDatabase:
            return [.folder]
        }
    }

    var allowsMultipleSelection: Bool {
        switch self {
        case .databaseFiles:
            return true
        case .folderForPendingDatabase:
            return false
        }
    }
}

@MainActor
@Observable
final class AppState {
    private enum AlertDismissAction {
        case presentPendingFolderPicker
        case resumeQueuedOpens
        case discardPendingAndResumeQueuedOpens
    }

    let pageSize = 100

    var sessions: [DatabaseSession] = []
    var selectedDatabaseID: UUID?
    var isPresentingImporter = false
    var importerMode: ImporterMode = .databaseFiles
    var pendingDatabaseOpen: PendingDatabaseOpen?
    var alert: AppAlert?

    private let browser: SQLiteBrowser
    private let bookmarkStore: SecurityScopedBookmarkStore
    private let fileManager: FileManager
    private var alertDismissAction: AlertDismissAction?
    private var queuedDatabaseURLs: [URL] = []

    init(
        browser: SQLiteBrowser = SQLiteBrowser(),
        bookmarkStore: SecurityScopedBookmarkStore = SecurityScopedBookmarkStore(),
        fileManager: FileManager = .default
    ) {
        self.browser = browser
        self.bookmarkStore = bookmarkStore
        self.fileManager = fileManager
    }

    var selectedSession: DatabaseSession? {
        guard let selectedDatabaseID else {
            return nil
        }

        return sessions.first(where: { $0.id == selectedDatabaseID })
    }

    var selectedTable: DatabaseTable? {
        guard
            let session = selectedSession,
            let selectedTableName = session.selectedTableName
        else {
            return nil
        }

        return session.tables.first(where: { $0.name == selectedTableName })
    }

    var canGoToPreviousPage: Bool {
        (selectedSession?.currentPageIndex ?? 0) > 0
    }

    var canGoToNextPage: Bool {
        guard let page = selectedSession?.page else {
            return false
        }

        return page.pageEnd < page.rowCount
    }

    var importerAllowedContentTypes: [UTType] {
        importerMode.allowedContentTypes
    }

    var importerAllowsMultipleSelection: Bool {
        importerMode.allowsMultipleSelection
    }

    func presentOpenPanel() {
        importerMode = .databaseFiles
        isPresentingImporter = true
    }

    func handleImporterResult(result: Result<[URL], Error>) async {
        let currentImporterMode = importerMode
        isPresentingImporter = false
        importerMode = .databaseFiles

        do {
            let urls = try result.get()

            switch currentImporterMode {
            case .databaseFiles:
                queuedDatabaseURLs.append(contentsOf: urls)
                await processQueuedDatabaseURLs()
            case .folderForPendingDatabase:
                guard let selectedFolderURL = urls.first else {
                    presentAlert(
                        title: "Folder Access Required",
                        message: "This database uses SQLite WAL sidecar files. Select its folder or one of its parent folders to open it.",
                        dismissAction: .discardPendingAndResumeQueuedOpens
                    )
                    return
                }

                await handleAuthorizedFolderSelection(selectedFolderURL)
            }
        } catch {
            switch currentImporterMode {
            case .databaseFiles:
                presentAlert(
                    title: "Couldn’t Open Database",
                    message: error.localizedDescription,
                    dismissAction: queuedDatabaseURLs.isEmpty ? nil : .resumeQueuedOpens
                )
            case .folderForPendingDatabase:
                presentAlert(
                    title: "Folder Access Required",
                    message: "This database uses SQLite WAL sidecar files. Select its folder or one of its parent folders to open it.",
                    dismissAction: .discardPendingAndResumeQueuedOpens
                )
            }
        }
    }

    func handleImporterCancellation() {
        let currentImporterMode = importerMode
        isPresentingImporter = false
        importerMode = .databaseFiles

        guard currentImporterMode == .folderForPendingDatabase, pendingDatabaseOpen != nil else {
            return
        }

        presentAlert(
            title: "Folder Access Required",
            message: "This database uses SQLite WAL sidecar files. Select its folder or one of its parent folders to open it.",
            dismissAction: .discardPendingAndResumeQueuedOpens
        )
    }

    func requiresFolderAuthorization(for databaseURL: URL) -> Bool {
        companionSidecarURLs(for: databaseURL)
            .contains { fileManager.fileExists(atPath: $0.path) }
    }

    func companionSidecarURLs(for databaseURL: URL) -> [URL] {
        let normalizedURL = normalizedDatabaseURL(databaseURL)
        return [
            URL(fileURLWithPath: normalizedURL.path + "-wal"),
            URL(fileURLWithPath: normalizedURL.path + "-shm")
        ]
    }

    func presentPendingFolderPickerIfNeeded() {
        guard pendingDatabaseOpen != nil else {
            return
        }

        importerMode = .folderForPendingDatabase
        isPresentingImporter = true
    }

    func selectDatabase(id: UUID?) async {
        selectedDatabaseID = id

        guard let id, let index = sessionIndex(for: id) else {
            return
        }

        if sessions[index].selectedTableName == nil {
            sessions[index].selectedTableName = sessions[index].tables.first?.name
        }

        guard sessions[index].selectedTableName != nil else {
            return
        }

        if sessions[index].page == nil {
            await loadSelectedPage(for: id, forceRefresh: false)
        }
    }

    func selectTable(named tableName: String?) async {
        guard let databaseID = selectedDatabaseID, let index = sessionIndex(for: databaseID) else {
            return
        }

        sessions[index].selectedTableName = tableName
        sessions[index].currentPageIndex = 0
        sessions[index].page = nil
        sessions[index].lastErrorMessage = nil

        guard tableName != nil else {
            return
        }

        await loadSelectedPage(for: databaseID, forceRefresh: false)
    }

    func loadPreviousPage() async {
        guard let databaseID = selectedDatabaseID, let index = sessionIndex(for: databaseID) else {
            return
        }

        guard sessions[index].currentPageIndex > 0 else {
            return
        }

        sessions[index].currentPageIndex -= 1
        await loadSelectedPage(for: databaseID, forceRefresh: true)
    }

    func loadNextPage() async {
        guard let databaseID = selectedDatabaseID, let index = sessionIndex(for: databaseID) else {
            return
        }

        let currentRowCount = sessions[index].page?.rowCount ?? sessions[index].tables.first(where: {
            $0.name == sessions[index].selectedTableName
        })?.rowCount ?? 0
        let nextOffset = (sessions[index].currentPageIndex + 1) * pageSize

        guard nextOffset < currentRowCount else {
            return
        }

        sessions[index].currentPageIndex += 1
        await loadSelectedPage(for: databaseID, forceRefresh: true)
    }

    func refreshSelectedTable() async {
        guard let databaseID = selectedDatabaseID else {
            return
        }

        await loadSelectedPage(for: databaseID, forceRefresh: true)
    }

    func closeDatabase(id: UUID) async {
        guard let index = sessionIndex(for: id) else {
            return
        }

        let session = sessions.remove(at: index)
        await browser.closeDatabase(id: id)
        releaseAccessScopes(session.activeAccessScopes)

        guard selectedDatabaseID == id else {
            return
        }

        if sessions.indices.contains(index) {
            await selectDatabase(id: sessions[index].id)
        } else {
            await selectDatabase(id: sessions.last?.id)
        }
    }

    func clearAlert() {
        let dismissAction = alertDismissAction
        alertDismissAction = nil
        alert = nil

        switch dismissAction {
        case .presentPendingFolderPicker:
            presentPendingFolderPickerIfNeeded()
        case .resumeQueuedOpens:
            Task {
                await processQueuedDatabaseURLs()
            }
        case .discardPendingAndResumeQueuedOpens:
            discardPendingDatabaseOpen()
            Task {
                await processQueuedDatabaseURLs()
            }
        case nil:
            break
        }
    }

    private func processQueuedDatabaseURLs() async {
        while pendingDatabaseOpen == nil, !queuedDatabaseURLs.isEmpty {
            let nextURL = queuedDatabaseURLs.removeFirst()
            await beginDatabaseOpen(at: nextURL)
        }
    }

    private func beginDatabaseOpen(at url: URL) async {
        let normalizedURL = normalizedDatabaseURL(url)

        if let existingSession = sessions.first(where: { $0.url.standardizedFileURL == normalizedURL }) {
            await selectDatabase(id: existingSession.id)
            return
        }

        let fileScope = startAccessScope(for: normalizedURL, kind: .databaseFile)
        let expectedFolderURL = SecurityScopedBookmarkStore.normalizedDirectoryURL(
            normalizedURL.deletingLastPathComponent()
        )

        if requiresFolderAuthorization(for: normalizedURL) {
            if let folderScope = bookmarkStore.resolveStoredFolderScope(covering: expectedFolderURL) {
                await openDatabase(
                    at: normalizedURL,
                    accessScopes: [fileScope, folderScope],
                    allowFolderRecovery: false
                )
            } else {
                pendingDatabaseOpen = PendingDatabaseOpen(
                    databaseURL: normalizedURL,
                    expectedFolderURL: expectedFolderURL,
                    fileScope: fileScope
                )
                presentPendingFolderPickerIfNeeded()
            }

            return
        }

        await openDatabase(
            at: normalizedURL,
            accessScopes: [fileScope],
            allowFolderRecovery: true
        )
    }

    private func handleAuthorizedFolderSelection(_ folderURL: URL) async {
        guard let pendingDatabaseOpen else {
            return
        }

        let normalizedFolderURL = SecurityScopedBookmarkStore.normalizedDirectoryURL(folderURL)
        let folderScope = startAccessScope(for: normalizedFolderURL, kind: .containingFolder)

        guard SecurityScopedBookmarkStore.isSameOrAncestor(normalizedFolderURL, of: pendingDatabaseOpen.expectedFolderURL) else {
            releaseAccessScopes([folderScope])
            presentAlert(
                title: "Wrong Folder Selected",
                message: "Select \(pendingDatabaseOpen.expectedFolderURL.path) or one of its parent folders to open this database.",
                dismissAction: .presentPendingFolderPicker
            )
            return
        }

        do {
            try bookmarkStore.saveReadOnlyBookmark(for: normalizedFolderURL)
        } catch {
            releaseAccessScopes([folderScope])
            presentAlert(
                title: "Couldn’t Remember Folder Access",
                message: error.localizedDescription,
                dismissAction: .discardPendingAndResumeQueuedOpens
            )
            return
        }

        self.pendingDatabaseOpen = nil

        await openDatabase(
            at: pendingDatabaseOpen.databaseURL,
            accessScopes: [pendingDatabaseOpen.fileScope, folderScope],
            allowFolderRecovery: false
        )
    }

    private func openDatabase(
        at databaseURL: URL,
        accessScopes: [ActiveSecurityScope],
        allowFolderRecovery: Bool
    ) async {
        do {
            let openedDatabase = try await browser.openDatabase(at: databaseURL)
            let firstTableName = openedDatabase.tables.first?.name
            let session = DatabaseSession(
                id: openedDatabase.id,
                url: databaseURL,
                tables: openedDatabase.tables,
                selectedTableName: firstTableName,
                currentPageIndex: 0,
                page: nil,
                isLoadingPage: false,
                lastErrorMessage: nil,
                activeAccessScopes: accessScopes
            )

            sessions.append(session)
            selectedDatabaseID = session.id

            if firstTableName != nil {
                await loadSelectedPage(for: session.id, forceRefresh: false)
            }

            if alert == nil {
                await processQueuedDatabaseURLs()
            }
        } catch {
            if shouldRecoverWithFolderAuthorization(
                from: error,
                databaseURL: databaseURL,
                accessScopes: accessScopes,
                allowFolderRecovery: allowFolderRecovery
            ) {
                guard let fileScope = accessScopes.first(where: { $0.kind == .databaseFile }) else {
                    releaseAccessScopes(accessScopes)
                    presentAlert(
                        title: "Couldn’t Open Database",
                        message: error.localizedDescription,
                        dismissAction: queuedDatabaseURLs.isEmpty ? nil : .resumeQueuedOpens
                    )
                    return
                }

                pendingDatabaseOpen = PendingDatabaseOpen(
                    databaseURL: databaseURL,
                    expectedFolderURL: SecurityScopedBookmarkStore.normalizedDirectoryURL(databaseURL.deletingLastPathComponent()),
                    fileScope: fileScope
                )
                releaseAccessScopes(accessScopes.filter { $0.kind != .databaseFile })
                presentPendingFolderPickerIfNeeded()
                return
            }

            releaseAccessScopes(accessScopes)
            presentAlert(
                title: "Couldn’t Open Database",
                message: error.localizedDescription,
                dismissAction: queuedDatabaseURLs.isEmpty ? nil : .resumeQueuedOpens
            )
        }
    }

    private func loadSelectedPage(for databaseID: UUID, forceRefresh: Bool) async {
        guard let index = sessionIndex(for: databaseID) else {
            return
        }

        guard let selectedTableName = sessions[index].selectedTableName else {
            sessions[index].page = nil
            return
        }

        if sessions[index].isLoadingPage {
            return
        }

        let offset = sessions[index].currentPageIndex * pageSize
        sessions[index].isLoadingPage = true
        sessions[index].lastErrorMessage = nil

        do {
            let loadedData: SQLiteBrowser.LoadedTableData
            if forceRefresh {
                loadedData = try await browser.refreshPage(
                    for: databaseID,
                    table: selectedTableName,
                    pageSize: pageSize,
                    offset: offset
                )
            } else {
                loadedData = try await browser.loadSchemaAndPage(
                    for: databaseID,
                    table: selectedTableName,
                    pageSize: pageSize,
                    offset: offset
                )
            }

            guard let refreshedIndex = sessionIndex(for: databaseID) else {
                return
            }

            upsert(loadedData.table, in: &sessions[refreshedIndex].tables)
            sessions[refreshedIndex].page = loadedData.page
            sessions[refreshedIndex].isLoadingPage = false
        } catch {
            guard let refreshedIndex = sessionIndex(for: databaseID) else {
                return
            }

            sessions[refreshedIndex].page = nil
            sessions[refreshedIndex].isLoadingPage = false
            sessions[refreshedIndex].lastErrorMessage = error.localizedDescription
            presentAlert(
                title: "Couldn’t Load Table",
                message: error.localizedDescription,
                dismissAction: queuedDatabaseURLs.isEmpty ? nil : .resumeQueuedOpens
            )
        }
    }

    private func discardPendingDatabaseOpen() {
        guard let pendingDatabaseOpen else {
            return
        }

        self.pendingDatabaseOpen = nil
        releaseAccessScopes([pendingDatabaseOpen.fileScope])
    }

    private func sessionIndex(for id: UUID) -> Int? {
        sessions.firstIndex(where: { $0.id == id })
    }

    private func normalizedDatabaseURL(_ url: URL) -> URL {
        url
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private func startAccessScope(for url: URL, kind: SecurityScopeKind) -> ActiveSecurityScope {
        let normalizedURL = kind == .containingFolder
            ? SecurityScopedBookmarkStore.normalizedDirectoryURL(url)
            : normalizedDatabaseURL(url)

        return ActiveSecurityScope(
            url: normalizedURL,
            kind: kind,
            startedAccess: normalizedURL.startAccessingSecurityScopedResource()
        )
    }

    private func releaseAccessScopes(_ accessScopes: [ActiveSecurityScope]) {
        for accessScope in accessScopes.reversed() where accessScope.startedAccess {
            accessScope.url.stopAccessingSecurityScopedResource()
        }
    }

    private func shouldRecoverWithFolderAuthorization(
        from error: Error,
        databaseURL: URL,
        accessScopes: [ActiveSecurityScope],
        allowFolderRecovery: Bool
    ) -> Bool {
        guard allowFolderRecovery else {
            return false
        }

        guard !accessScopes.contains(where: { $0.kind == .containingFolder }) else {
            return false
        }

        guard error.localizedDescription.localizedCaseInsensitiveContains("authorization denied") else {
            return false
        }

        return companionSidecarURLs(for: databaseURL).count == 2
    }

    private func upsert(_ table: DatabaseTable, in tables: inout [DatabaseTable]) {
        if let index = tables.firstIndex(where: { $0.name == table.name }) {
            tables[index] = table
        } else {
            tables.append(table)
            tables.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func presentAlert(
        title: String,
        message: String,
        dismissAction: AlertDismissAction? = nil
    ) {
        alertDismissAction = dismissAction
        alert = AppAlert(title: title, message: message)
    }
}
