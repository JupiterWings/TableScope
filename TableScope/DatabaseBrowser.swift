//
//  DatabaseBrowser.swift
//  TableScope
//
//

import Foundation

actor DatabaseBrowser {
    typealias RemoteClientFactory = @Sendable (RemoteDatabaseSource) async throws -> any RemoteDatabaseClient

    nonisolated struct OpenedDatabaseHandle: Hashable, Sendable {
        let id: UUID
        let tables: [DatabaseTable]
    }

    nonisolated struct LoadedTableData: Hashable, Sendable {
        let table: DatabaseTable
        let page: TablePage
    }

    private nonisolated enum BrowserError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message):
                return message
            }
        }
    }

    private struct RemoteConnection {
        let token: UUID
        let source: RemoteDatabaseSource
        let client: any RemoteDatabaseClient
        let remoteSessionID: String
    }

    private enum Connection {
        case local
        case remote(RemoteConnection)
    }

    private let localBrowser: SQLiteBrowser
    private let remoteClientFactory: RemoteClientFactory
    private var connections: [UUID: Connection] = [:]

    init(
        localBrowser: SQLiteBrowser = SQLiteBrowser(),
        remoteClientFactory: @escaping RemoteClientFactory = DatabaseBrowser.defaultRemoteClientFactory
    ) {
        self.localBrowser = localBrowser
        self.remoteClientFactory = remoteClientFactory
    }

    func openDatabase(source: DatabaseSource) async throws -> OpenedDatabaseHandle {
        switch source.normalized {
        case .localFile(let localSource):
            let openedDatabase = try await localBrowser.openDatabase(at: localSource.url)
            connections[openedDatabase.id] = .local
            return OpenedDatabaseHandle(id: openedDatabase.id, tables: openedDatabase.tables)
        case .remoteSQLite(let remoteSource):
            let client = try await remoteClientFactory(remoteSource)

            do {
                let openedDatabase = try await client.openDatabase(at: remoteSource.databasePath)
                let databaseID = UUID()
                let remoteConnection = RemoteConnection(
                    token: UUID(),
                    source: remoteSource,
                    client: client,
                    remoteSessionID: openedDatabase.sessionID
                )
                connections[databaseID] = .remote(remoteConnection)
                return OpenedDatabaseHandle(id: databaseID, tables: openedDatabase.tables)
            } catch {
                await client.shutdown()
                throw error
            }
        }
    }

    func closeDatabase(id: UUID) async {
        guard let connection = connections.removeValue(forKey: id) else {
            return
        }

        switch connection {
        case .local:
            await localBrowser.closeDatabase(id: id)
        case .remote(let remoteConnection):
            await remoteConnection.client.closeDatabase(sessionID: remoteConnection.remoteSessionID)
            await remoteConnection.client.shutdown()
        }
    }

    func listTables(for id: UUID) async throws -> [DatabaseTable] {
        switch try connection(for: id) {
        case .local:
            return try await localBrowser.listTables(for: id)
        case .remote:
            return try await performRemoteOperation(for: id) { remoteConnection in
                try await remoteConnection.client.listTables(sessionID: remoteConnection.remoteSessionID)
            }
        }
    }

    func loadSchemaAndPage(
        for id: UUID,
        table tableName: String,
        pageSize: Int,
        offset: Int
    ) async throws -> LoadedTableData {
        switch try connection(for: id) {
        case .local:
            let loadedData = try await localBrowser.loadSchemaAndPage(
                for: id,
                table: tableName,
                pageSize: pageSize,
                offset: offset
            )
            return LoadedTableData(table: loadedData.table, page: loadedData.page)
        case .remote:
            let loadedData = try await performRemoteOperation(for: id) { remoteConnection in
                try await remoteConnection.client.loadSchemaAndPage(
                    sessionID: remoteConnection.remoteSessionID,
                    tableName: tableName,
                    pageSize: pageSize,
                    offset: offset
                )
            }
            return LoadedTableData(table: loadedData.table, page: loadedData.page)
        }
    }

    func refreshPage(
        for id: UUID,
        table tableName: String,
        pageSize: Int,
        offset: Int
    ) async throws -> LoadedTableData {
        switch try connection(for: id) {
        case .local:
            let loadedData = try await localBrowser.refreshPage(
                for: id,
                table: tableName,
                pageSize: pageSize,
                offset: offset
            )
            return LoadedTableData(table: loadedData.table, page: loadedData.page)
        case .remote:
            let loadedData = try await performRemoteOperation(for: id) { remoteConnection in
                try await remoteConnection.client.refreshPage(
                    sessionID: remoteConnection.remoteSessionID,
                    tableName: tableName,
                    pageSize: pageSize,
                    offset: offset
                )
            }
            return LoadedTableData(table: loadedData.table, page: loadedData.page)
        }
    }

    private func connection(for id: UUID) throws -> Connection {
        guard let connection = connections[id] else {
            throw BrowserError.message("The selected database is no longer open.")
        }

        return connection
    }

    private func remoteConnection(for id: UUID) throws -> RemoteConnection {
        guard case .remote(let remoteConnection) = try connection(for: id) else {
            throw BrowserError.message("The selected database is not remote.")
        }

        return remoteConnection
    }

    private func performRemoteOperation<Result: Sendable>(
        for id: UUID,
        operation: @Sendable (RemoteConnection) async throws -> Result
    ) async throws -> Result {
        let remoteConnection = try remoteConnection(for: id)

        do {
            return try await operation(remoteConnection)
        } catch {
            guard shouldReconnect(after: error) else {
                throw error
            }

            let reconnected = try await reconnectRemoteConnection(for: id, from: remoteConnection)
            return try await operation(reconnected)
        }
    }

    private func shouldReconnect(after error: Error) -> Bool {
        !(error is RemoteProtocolError)
    }

    private func reconnectRemoteConnection(
        for id: UUID,
        from staleConnection: RemoteConnection
    ) async throws -> RemoteConnection {
        guard let currentConnection = connections[id] else {
            throw BrowserError.message("The selected database is no longer open.")
        }

        switch currentConnection {
        case .local:
            throw BrowserError.message("The selected database is not remote.")
        case .remote(let currentRemoteConnection):
            if currentRemoteConnection.token != staleConnection.token {
                return currentRemoteConnection
            }
        }

        let client = try await remoteClientFactory(staleConnection.source)

        do {
            let reopenedDatabase = try await client.openDatabase(at: staleConnection.source.databasePath)
            let reconnected = RemoteConnection(
                token: UUID(),
                source: staleConnection.source,
                client: client,
                remoteSessionID: reopenedDatabase.sessionID
            )
            connections[id] = .remote(reconnected)
            await staleConnection.client.shutdown()
            return reconnected
        } catch {
            await client.shutdown()
            throw error
        }
    }

    nonisolated private static let defaultRemoteClientFactory: RemoteClientFactory = { source in
        try await SSHRemoteDatabaseClient(hostAlias: source.hostAlias)
    }
}
