//
//  SQLiteBrowser.swift
//  TableScope
//
//

import Foundation
import SQLite3

actor SQLiteBrowser {
    private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    private var connections: [UUID: OpaquePointer] = [:]

    func openDatabase(at url: URL) throws -> OpenedDatabaseHandle {
        let databaseID = UUID()
        let handle = try openConnection(at: url)

        do {
            connections[databaseID] = handle
            let tables = try listTables(forConnection: handle)
            return OpenedDatabaseHandle(id: databaseID, tables: tables)
        } catch {
            connections.removeValue(forKey: databaseID)
            sqlite3_close_v2(handle)
            throw error
        }
    }

    func closeDatabase(id: UUID) {
        guard let handle = connections.removeValue(forKey: id) else {
            return
        }

        sqlite3_close_v2(handle)
    }

    func listTables(for id: UUID) throws -> [DatabaseTable] {
        try listTables(forConnection: try connection(for: id))
    }

    func loadSchemaAndPage(
        for id: UUID,
        table tableName: String,
        pageSize: Int,
        offset: Int
    ) throws -> LoadedTableData {
        let connection = try connection(for: id)
        let columns = try loadColumns(for: tableName, connection: connection)
        let rowCount = try loadRowCount(for: tableName, connection: connection)
        let orderingClause = try orderingClause(for: tableName, columns: columns, connection: connection)
        let rows = try loadRows(
            for: tableName,
            columns: columns,
            pageSize: pageSize,
            offset: offset,
            orderingClause: orderingClause,
            connection: connection
        )

        let table = DatabaseTable(
            name: tableName,
            columns: columns,
            rowCount: rowCount
        )
        let page = TablePage(
            tableName: tableName,
            rows: rows,
            rowCount: rowCount,
            pageIndex: max(0, offset / pageSize),
            pageSize: pageSize
        )

        return LoadedTableData(table: table, page: page)
    }

    func refreshPage(
        for id: UUID,
        table tableName: String,
        pageSize: Int,
        offset: Int
    ) throws -> LoadedTableData {
        try loadSchemaAndPage(for: id, table: tableName, pageSize: pageSize, offset: offset)
    }

    private func openConnection(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)

        guard result == SQLITE_OK, let handle else {
            if let handle {
                let message = errorMessage(from: handle, fallbackCode: result)
                sqlite3_close_v2(handle)
                throw BrowserError.message(message)
            }

            throw BrowserError.message("Unable to open the database.")
        }

        return handle
    }

    private func connection(for id: UUID) throws -> OpaquePointer {
        guard let handle = connections[id] else {
            throw BrowserError.message("The selected database is no longer open.")
        }

        return handle
    }

    private func listTables(forConnection connection: OpaquePointer) throws -> [DatabaseTable] {
        let sql = """
        SELECT name
        FROM sqlite_master
        WHERE type = 'table'
          AND name NOT LIKE 'sqlite_%'
        ORDER BY name COLLATE NOCASE;
        """

        let statement = try prepareStatement(sql: sql, connection: connection)
        defer { sqlite3_finalize(statement) }

        var tables: [DatabaseTable] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = stringValue(statement: statement, column: 0)
            tables.append(DatabaseTable(name: name, columns: [], rowCount: 0))
        }

        return tables
    }

    private func loadColumns(for tableName: String, connection: OpaquePointer) throws -> [TableColumnInfo] {
        let sql = "PRAGMA table_info(\(quotedIdentifier(tableName)));"
        let statement = try prepareStatement(sql: sql, connection: connection)
        defer { sqlite3_finalize(statement) }

        var columns: [TableColumnInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = stringValue(statement: statement, column: 1)
            let declaredType = stringValue(statement: statement, column: 2)
            let notNull = sqlite3_column_int(statement, 3) != 0
            let primaryKeyIndex = Int(sqlite3_column_int(statement, 5))

            columns.append(
                TableColumnInfo(
                    name: name,
                    declaredType: declaredType,
                    primaryKeyIndex: primaryKeyIndex == 0 ? nil : primaryKeyIndex,
                    isNullable: !notNull
                )
            )
        }

        return columns
    }

    private func loadRowCount(for tableName: String, connection: OpaquePointer) throws -> Int {
        let sql = "SELECT COUNT(*) FROM \(quotedIdentifier(tableName));"
        let statement = try prepareStatement(sql: sql, connection: connection)
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw BrowserError.message("Unable to count rows for \(tableName).")
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    private func orderingClause(
        for tableName: String,
        columns: [TableColumnInfo],
        connection: OpaquePointer
    ) throws -> String {
        let createStatement = try tableDefinition(for: tableName, connection: connection)

        if createStatement?.localizedCaseInsensitiveContains("WITHOUT ROWID") == true {
            let primaryKeyColumns = columns
                .filter { $0.primaryKeyIndex != nil }
                .sorted { ($0.primaryKeyIndex ?? 0) < ($1.primaryKeyIndex ?? 0) }

            guard !primaryKeyColumns.isEmpty else {
                // WITHOUT ROWID tables must define a primary key, but keep a raw-order fallback.
                return ""
            }

            let orderedColumns = primaryKeyColumns
                .map(\.name)
                .map(quotedIdentifier(_:))
                .joined(separator: ", ")

            return " ORDER BY \(orderedColumns)"
        }

        return " ORDER BY rowid"
    }

    private func tableDefinition(for tableName: String, connection: OpaquePointer) throws -> String? {
        let sql = """
        SELECT sql
        FROM sqlite_master
        WHERE type = 'table'
          AND name = ?;
        """
        let statement = try prepareStatement(sql: sql, connection: connection)
        defer { sqlite3_finalize(statement) }

        try bind(text: tableName, to: 1, statement: statement, connection: connection)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return stringValue(statement: statement, column: 0)
    }

    private func loadRows(
        for tableName: String,
        columns: [TableColumnInfo],
        pageSize: Int,
        offset: Int,
        orderingClause: String,
        connection: OpaquePointer
    ) throws -> [TableRow] {
        let sql = """
        SELECT *
        FROM \(quotedIdentifier(tableName))\(orderingClause)
        LIMIT ? OFFSET ?;
        """
        let statement = try prepareStatement(sql: sql, connection: connection)
        defer { sqlite3_finalize(statement) }

        try bind(int64: Int64(pageSize), to: 1, statement: statement, connection: connection)
        try bind(int64: Int64(offset), to: 2, statement: statement, connection: connection)

        var rows: [TableRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var cells: [String: CellDisplayValue] = [:]

            for (columnIndex, column) in columns.enumerated() {
                cells[column.name] = cellValue(statement: statement, column: Int32(columnIndex))
            }

            rows.append(TableRow(id: "\(tableName):\(offset + rows.count)", cells: cells))
        }

        return rows
    }

    private func prepareStatement(sql: String, connection: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)

        guard result == SQLITE_OK, let statement else {
            throw BrowserError.message(errorMessage(from: connection, fallbackCode: result))
        }

        return statement
    }

    private func bind(text: String, to index: Int32, statement: OpaquePointer, connection: OpaquePointer) throws {
        let result = sqlite3_bind_text(statement, index, text, -1, sqliteTransientDestructor)
        guard result == SQLITE_OK else {
            throw BrowserError.message(errorMessage(from: connection, fallbackCode: result))
        }
    }

    private func bind(int64 value: Int64, to index: Int32, statement: OpaquePointer, connection: OpaquePointer) throws {
        let result = sqlite3_bind_int64(statement, index, value)
        guard result == SQLITE_OK else {
            throw BrowserError.message(errorMessage(from: connection, fallbackCode: result))
        }
    }

    private func stringValue(statement: OpaquePointer, column: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, column) else {
            return ""
        }

        return String(cString: cString)
    }

    private func cellValue(statement: OpaquePointer, column: Int32) -> CellDisplayValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            return .text(stringValue(statement: statement, column: column))
        case SQLITE_BLOB:
            return .blob(Int(sqlite3_column_bytes(statement, column)))
        default:
            return .null
        }
    }

    private func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func errorMessage(from connection: OpaquePointer, fallbackCode: Int32) -> String {
        if let cString = sqlite3_errmsg(connection) {
            return String(cString: cString)
        }

        return String(cString: sqlite3_errstr(fallbackCode))
    }
}
