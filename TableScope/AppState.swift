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

    var allowedContentTypes: [UTType] {
        [.data]
    }

    var allowsMultipleSelection: Bool {
        true
    }
}

@MainActor
@Observable
final class AppState {
    private enum AlertDismissAction {
        case resumeQueuedOpens
    }

    private enum OpenBehavior: Equatable {
        case userInitiated
        case restored
    }

    let pageSize = 100

    var sessions: [DatabaseSession] = []
    var selectedDatabaseID: UUID?
    var isPresentingImporter = false
    var isPresentingRemoteDatabaseSheet = false
    var importerMode: ImporterMode = .databaseFiles
    var remoteDatabaseDraft = RemoteDatabaseDraft()
    var alert: AppAlert?

    private let browser: DatabaseBrowser
    private let workspaceStore: WorkspacePersistenceStore
    private var alertDismissAction: AlertDismissAction?
    private var queuedDatabaseSources: [DatabaseSource] = []
    private var hasRestoredPersistedSessions = false

    init(
        browser: DatabaseBrowser = DatabaseBrowser(),
        workspaceStore: WorkspacePersistenceStore? = nil
    ) {
        self.browser = browser
        self.workspaceStore = workspaceStore ?? WorkspacePersistenceStore()
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

    func presentRemoteDatabaseSheet() {
        if remoteDatabaseDraft.hostAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remoteDatabaseDraft.hostAlias = RemoteHelperConfiguration.defaultHostAlias
        }

        remoteDatabaseDraft.databasePath = ""
        isPresentingRemoteDatabaseSheet = true
    }

    func confirmRemoteDatabaseDraft() async {
        let hostAlias = remoteDatabaseDraft.hostAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let databasePath = remoteDatabaseDraft.databasePath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !hostAlias.isEmpty, !databasePath.isEmpty else {
            presentAlert(
                title: "Couldn’t Open Remote Database",
                message: "Provide both an SSH host alias and a remote database path."
            )
            return
        }

        isPresentingRemoteDatabaseSheet = false
        remoteDatabaseDraft.hostAlias = hostAlias
        remoteDatabaseDraft.databasePath = ""
        await openRemoteDatabase(hostAlias: hostAlias, databasePath: databasePath)
    }

    func cancelRemoteDatabaseSheet() {
        isPresentingRemoteDatabaseSheet = false
    }

    func openRemoteDatabase(hostAlias: String, databasePath: String) async {
        queuedDatabaseSources.append(
            .remoteSQLite(
                RemoteDatabaseSource(
                    hostAlias: hostAlias,
                    databasePath: databasePath
                )
            )
        )
        await processQueuedDatabaseSources()
    }

    func restorePersistedSessionsIfNeeded() async {
        guard !hasRestoredPersistedSessions else {
            return
        }

        hasRestoredPersistedSessions = true

        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
            return
        }

        guard let persistedState = workspaceStore.load() else {
            return
        }

        var firstRestoredSessionID: UUID?

        for persistedSource in persistedState.databaseSources {
            guard let databaseSource = persistedSource.databaseSource else {
                continue
            }

            if let localFileURL = databaseSource.localFileURL,
               !FileManager.default.fileExists(atPath: localFileURL.path) {
                continue
            }

            if let restoredSessionID = await beginDatabaseOpen(
                source: databaseSource,
                behavior: .restored
            ), firstRestoredSessionID == nil {
                firstRestoredSessionID = restoredSessionID
            }
        }

        persistWorkspace()

        guard let firstRestoredSessionID else {
            return
        }

        await selectDatabase(id: firstRestoredSessionID)
    }

    func handleImporterResult(result: Result<[URL], Error>) async {
        isPresentingImporter = false

        do {
            queuedDatabaseSources.append(
                contentsOf: try result.get().map {
                    .localFile(LocalFileDatabaseSource(url: $0))
                }
            )
            await processQueuedDatabaseSources()
        } catch {
            presentAlert(
                title: "Couldn’t Open Database",
                message: error.localizedDescription,
                dismissAction: queuedDatabaseSources.isEmpty ? nil : .resumeQueuedOpens
            )
        }
    }

    func handleImporterCancellation() {
        isPresentingImporter = false
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

        sessions.remove(at: index)
        persistWorkspace()
        await browser.closeDatabase(id: id)

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
        case .resumeQueuedOpens:
            Task {
                await processQueuedDatabaseSources()
            }
        case nil:
            break
        }
    }

    private func processQueuedDatabaseSources() async {
        while !queuedDatabaseSources.isEmpty {
            let nextSource = queuedDatabaseSources.removeFirst()
            await beginDatabaseOpen(source: nextSource, behavior: .userInitiated)
        }
    }

    @discardableResult
    private func beginDatabaseOpen(source: DatabaseSource, behavior: OpenBehavior) async -> UUID? {
        let normalizedSource = normalizedDatabaseSource(source)

        if let existingSession = sessions.first(where: { $0.source == normalizedSource }) {
            if behavior == .userInitiated {
                await selectDatabase(id: existingSession.id)
            }

            return existingSession.id
        }

        return await openDatabase(source: normalizedSource, behavior: behavior)
    }

    @discardableResult
    private func openDatabase(source: DatabaseSource, behavior: OpenBehavior) async -> UUID? {
        do {
            let openedDatabase = try await browser.openDatabase(source: source)
            let firstTableName = behavior == .userInitiated ? openedDatabase.tables.first?.name : nil
            let session = DatabaseSession(
                id: openedDatabase.id,
                source: source,
                tables: openedDatabase.tables,
                selectedTableName: firstTableName,
                currentPageIndex: 0,
                page: nil,
                isLoadingPage: false,
                lastErrorMessage: nil
            )

            sessions.append(session)
            persistWorkspace()

            if behavior == .userInitiated {
                selectedDatabaseID = session.id
            }

            if behavior == .userInitiated, firstTableName != nil {
                await loadSelectedPage(for: session.id, forceRefresh: false)
            }

            if behavior == .userInitiated, alert == nil {
                await processQueuedDatabaseSources()
            }

            return session.id
        } catch {
            if behavior == .userInitiated {
                presentAlert(
                    title: source.isRemote ? "Couldn’t Open Remote Database" : "Couldn’t Open Database",
                    message: error.localizedDescription,
                    dismissAction: queuedDatabaseSources.isEmpty ? nil : .resumeQueuedOpens
                )
            }

            return nil
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
            let loadedData: DatabaseBrowser.LoadedTableData
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
                dismissAction: queuedDatabaseSources.isEmpty ? nil : .resumeQueuedOpens
            )
        }
    }

    private func sessionIndex(for id: UUID) -> Int? {
        sessions.firstIndex(where: { $0.id == id })
    }

    private func normalizedDatabaseSource(_ source: DatabaseSource) -> DatabaseSource {
        source.normalized
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

    private func persistWorkspace() {
        guard !sessions.isEmpty else {
            workspaceStore.clear()
            return
        }

        workspaceStore.save(databaseSources: sessions.map(\.source))
    }
}
