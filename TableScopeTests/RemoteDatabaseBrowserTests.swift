//
//  RemoteDatabaseBrowserTests.swift
//  TableScopeTests
//
//

import XCTest
@testable import TableScope

final class RemoteDatabaseBrowserTests: XCTestCase {
    func testRemoteSourceNormalizationPreservesHomeShortcut() {
        let source = RemoteDatabaseSource(
            hostAlias: " torvalds1 ",
            databasePath: "~/Documents/GitHub/../stock_rules/backend/disiplin.db"
        )

        XCTAssertEqual(source.normalized.hostAlias, "torvalds1")
        XCTAssertEqual(
            source.normalized.databasePath,
            "~/Documents/stock_rules/backend/disiplin.db"
        )
    }

    func testRemoteDatabaseBrowserLoadsSchemaAndPageThroughRemoteClient() async throws {
        let fakeClient = FakeRemoteDatabaseClient()
        let browser = DatabaseBrowser(
            remoteClientFactory: { _ in
                fakeClient
            }
        )
        let source = DatabaseSource.remoteSQLite(
            RemoteDatabaseSource(
                hostAlias: "torvalds1",
                databasePath: "/var/data/sample.sqlite3"
            )
        )

        let openedDatabase = try await browser.openDatabase(source: source)
        let loadedData = try await browser.loadSchemaAndPage(
            for: openedDatabase.id,
            table: "people",
            pageSize: 2,
            offset: 0
        )

        XCTAssertEqual(openedDatabase.tables.map(\.name), ["people"])
        XCTAssertEqual(loadedData.table.columns.map(\.name), ["id", "name"])
        XCTAssertEqual(loadedData.page.rows.map { $0.value(for: "name") }, [.text("Ada"), .text("Grace")])

        await browser.closeDatabase(id: openedDatabase.id)

        let isShutdown = await fakeClient.shutdownState()
        XCTAssertTrue(isShutdown)
    }

    func testRemoteDatabaseBrowserReconnectsAndRetriesAfterTransportFailure() async throws {
        let firstClient = ScriptedRemoteDatabaseClient(
            openResponse: RemoteDatabaseOpenResponse(
                sessionID: "remote-session-1",
                tables: [DatabaseTable(name: "people", columns: [], rowCount: 0)]
            ),
            pageResponse: nil,
            pageError: SimulatedTransportFailure()
        )
        let secondClient = ScriptedRemoteDatabaseClient(
            openResponse: RemoteDatabaseOpenResponse(
                sessionID: "remote-session-2",
                tables: [DatabaseTable(name: "people", columns: [], rowCount: 0)]
            ),
            pageResponse: makePeoplePage(pageSize: 2),
            pageError: nil
        )
        let factory = SequencedRemoteClientFactory(
            clients: [firstClient, secondClient]
        )
        let browser = DatabaseBrowser(
            remoteClientFactory: { _ in
                try await factory.nextClient()
            }
        )
        let source = DatabaseSource.remoteSQLite(
            RemoteDatabaseSource(
                hostAlias: "torvalds1",
                databasePath: "/var/data/sample.sqlite3"
            )
        )

        let openedDatabase = try await browser.openDatabase(source: source)
        let loadedData = try await browser.loadSchemaAndPage(
            for: openedDatabase.id,
            table: "people",
            pageSize: 2,
            offset: 0
        )
        let firstOpenedPaths = await firstClient.openedPaths()
        let secondOpenedPaths = await secondClient.openedPaths()
        let firstShutdownState = await firstClient.shutdownState()

        XCTAssertEqual(loadedData.page.rows.map { $0.value(for: "name") }, [.text("Ada"), .text("Grace")])
        XCTAssertEqual(firstOpenedPaths, ["/var/data/sample.sqlite3"])
        XCTAssertEqual(secondOpenedPaths, ["/var/data/sample.sqlite3"])
        XCTAssertTrue(firstShutdownState)

        await browser.closeDatabase(id: openedDatabase.id)
        let secondShutdownState = await secondClient.shutdownState()

        XCTAssertTrue(secondShutdownState)
    }

    func testRestorePersistedRemoteSourceDoesNotRequireLocalFileExistence() async throws {
        let workspaceStore = makeWorkspaceStore()
        await MainActor.run {
            workspaceStore.save(
                databaseSources: [
                    .remoteSQLite(
                        RemoteDatabaseSource(
                            hostAlias: "torvalds1",
                            databasePath: "/var/data/sample.sqlite3"
                        )
                    )
                ]
            )
        }

        let fakeClient = FakeRemoteDatabaseClient()
        let browser = DatabaseBrowser(
            remoteClientFactory: { _ in
                fakeClient
            }
        )
        let appState = await MainActor.run {
            AppState(browser: browser, workspaceStore: workspaceStore)
        }

        await appState.restorePersistedSessionsIfNeeded()

        let sessions = await MainActor.run { appState.sessions }
        let selectedDatabaseID = await MainActor.run { appState.selectedDatabaseID }

        let firstSession = sessions.first
        let remoteSource = firstSession?.source.remoteSource

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(remoteSource?.hostAlias, "torvalds1")
        XCTAssertEqual(remoteSource?.databasePath, "/var/data/sample.sqlite3")
        XCTAssertEqual(selectedDatabaseID, firstSession?.id)
        XCTAssertNotNil(firstSession?.page)
    }

    private func makeWorkspaceStore() -> WorkspacePersistenceStore {
        let suiteName = "TableScopeTests.RemoteBrowser.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        return WorkspacePersistenceStore(
            defaults: defaults,
            key: "TableScopeTests.persistedWorkspaceState"
        )
    }
}

private actor FakeRemoteDatabaseClient: RemoteDatabaseClient {
    private(set) var isShutdown = false

    func openDatabase(at path: String) async throws -> RemoteDatabaseOpenResponse {
        RemoteDatabaseOpenResponse(
            sessionID: "remote-session-1",
            tables: [
                DatabaseTable(name: "people", columns: [], rowCount: 0)
            ]
        )
    }

    func listTables(sessionID: String) async throws -> [DatabaseTable] {
        [
            DatabaseTable(name: "people", columns: [], rowCount: 0)
        ]
    }

    func loadSchemaAndPage(
        sessionID: String,
        tableName: String,
        pageSize: Int,
        offset: Int
    ) async throws -> RemoteDatabasePageResponse {
        RemoteDatabasePageResponse(
            table: DatabaseTable(
                name: "people",
                columns: [
                    TableColumnInfo(name: "id", declaredType: "INTEGER", primaryKeyIndex: 1, isNullable: false),
                    TableColumnInfo(name: "name", declaredType: "TEXT", primaryKeyIndex: nil, isNullable: false)
                ],
                rowCount: 2
            ),
            page: TablePage(
                tableName: "people",
                rows: [
                    TableRow(
                        id: "people:0",
                        cells: [
                            "id": .integer(1),
                            "name": .text("Ada")
                        ]
                    ),
                    TableRow(
                        id: "people:1",
                        cells: [
                            "id": .integer(2),
                            "name": .text("Grace")
                        ]
                    )
                ],
                rowCount: 2,
                pageIndex: 0,
                pageSize: pageSize
            )
        )
    }

    func refreshPage(
        sessionID: String,
        tableName: String,
        pageSize: Int,
        offset: Int
    ) async throws -> RemoteDatabasePageResponse {
        try await loadSchemaAndPage(
            sessionID: sessionID,
            tableName: tableName,
            pageSize: pageSize,
            offset: offset
        )
    }

    func closeDatabase(sessionID: String) async {}

    func shutdown() async {
        isShutdown = true
    }

    func shutdownState() -> Bool {
        isShutdown
    }
}

private actor SequencedRemoteClientFactory {
    private var remainingClients: [any RemoteDatabaseClient]

    init(clients: [any RemoteDatabaseClient]) {
        self.remainingClients = clients
    }

    func nextClient() throws -> any RemoteDatabaseClient {
        guard !remainingClients.isEmpty else {
            throw SimulatedTransportFailure()
        }

        return remainingClients.removeFirst()
    }
}

private actor ScriptedRemoteDatabaseClient: RemoteDatabaseClient {
    private let openResponse: RemoteDatabaseOpenResponse
    private let pageResponse: RemoteDatabasePageResponse?
    private let pageError: Error?
    private var isShutdown = false
    private var openCalls: [String] = []

    init(
        openResponse: RemoteDatabaseOpenResponse,
        pageResponse: RemoteDatabasePageResponse?,
        pageError: Error?
    ) {
        self.openResponse = openResponse
        self.pageResponse = pageResponse
        self.pageError = pageError
    }

    func openDatabase(at path: String) async throws -> RemoteDatabaseOpenResponse {
        openCalls.append(path)
        return openResponse
    }

    func listTables(sessionID: String) async throws -> [DatabaseTable] {
        openResponse.tables
    }

    func loadSchemaAndPage(
        sessionID: String,
        tableName: String,
        pageSize: Int,
        offset: Int
    ) async throws -> RemoteDatabasePageResponse {
        if let pageError {
            throw pageError
        }

        guard let pageResponse else {
            throw SimulatedTransportFailure()
        }

        return pageResponse
    }

    func refreshPage(
        sessionID: String,
        tableName: String,
        pageSize: Int,
        offset: Int
    ) async throws -> RemoteDatabasePageResponse {
        try await loadSchemaAndPage(
            sessionID: sessionID,
            tableName: tableName,
            pageSize: pageSize,
            offset: offset
        )
    }

    func closeDatabase(sessionID: String) async {}

    func shutdown() async {
        isShutdown = true
    }

    func shutdownState() -> Bool {
        isShutdown
    }

    func openedPaths() -> [String] {
        openCalls
    }
}

private struct SimulatedTransportFailure: Error {}

private func makePeoplePage(pageSize: Int) -> RemoteDatabasePageResponse {
    RemoteDatabasePageResponse(
        table: DatabaseTable(
            name: "people",
            columns: [
                TableColumnInfo(name: "id", declaredType: "INTEGER", primaryKeyIndex: 1, isNullable: false),
                TableColumnInfo(name: "name", declaredType: "TEXT", primaryKeyIndex: nil, isNullable: false)
            ],
            rowCount: 2
        ),
        page: TablePage(
            tableName: "people",
            rows: [
                TableRow(
                    id: "people:0",
                    cells: [
                        "id": .integer(1),
                        "name": .text("Ada")
                    ]
                ),
                TableRow(
                    id: "people:1",
                    cells: [
                        "id": .integer(2),
                        "name": .text("Grace")
                    ]
                )
            ],
            rowCount: 2,
            pageIndex: 0,
            pageSize: pageSize
        )
    )
}
