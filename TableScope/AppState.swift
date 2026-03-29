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

    let pageSize = 100

    var sessions: [DatabaseSession] = []
    var selectedDatabaseID: UUID?
    var isPresentingImporter = false
    var importerMode: ImporterMode = .databaseFiles
    var alert: AppAlert?

    private let browser: SQLiteBrowser
    private var alertDismissAction: AlertDismissAction?
    private var queuedDatabaseURLs: [URL] = []

    init(browser: SQLiteBrowser = SQLiteBrowser()) {
        self.browser = browser
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
        isPresentingImporter = false

        do {
            queuedDatabaseURLs.append(contentsOf: try result.get())
            await processQueuedDatabaseURLs()
        } catch {
            presentAlert(
                title: "Couldn’t Open Database",
                message: error.localizedDescription,
                dismissAction: queuedDatabaseURLs.isEmpty ? nil : .resumeQueuedOpens
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
                await processQueuedDatabaseURLs()
            }
        case nil:
            break
        }
    }

    private func processQueuedDatabaseURLs() async {
        while !queuedDatabaseURLs.isEmpty {
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

        await openDatabase(at: normalizedURL)
    }

    private func openDatabase(at databaseURL: URL) async {
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
                lastErrorMessage: nil
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

    private func sessionIndex(for id: UUID) -> Int? {
        sessions.firstIndex(where: { $0.id == id })
    }

    private func normalizedDatabaseURL(_ url: URL) -> URL {
        url
            .resolvingSymlinksInPath()
            .standardizedFileURL
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
