//
//  SQLiteModels.swift
//  TableScope
//
//

import Foundation

nonisolated enum SecurityScopeKind: String, Hashable, Sendable, Codable {
    case databaseFile
    case containingFolder
}

nonisolated struct ActiveSecurityScope: Hashable, Sendable {
    let url: URL
    let kind: SecurityScopeKind
    let startedAccess: Bool
}

nonisolated struct PendingDatabaseOpen: Hashable, Sendable {
    let databaseURL: URL
    let expectedFolderURL: URL
    let fileScope: ActiveSecurityScope
}

nonisolated struct DatabaseSession: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    var tables: [DatabaseTable]
    var selectedTableName: String?
    var currentPageIndex: Int
    var page: TablePage?
    var isLoadingPage: Bool
    var lastErrorMessage: String?
    let activeAccessScopes: [ActiveSecurityScope]

    nonisolated var displayName: String {
        url.lastPathComponent
    }

    nonisolated var parentPath: String {
        let path = url.deletingLastPathComponent().path
        return path.isEmpty ? "/" : path
    }
}

nonisolated struct DatabaseTable: Identifiable, Hashable, Sendable {
    let name: String
    var columns: [TableColumnInfo]
    var rowCount: Int

    nonisolated var id: String {
        name
    }
}

nonisolated struct TableColumnInfo: Identifiable, Hashable, Sendable {
    let name: String
    let declaredType: String
    let primaryKeyIndex: Int?
    let isNullable: Bool

    nonisolated var id: String {
        name
    }

    nonisolated var isPrimaryKey: Bool {
        primaryKeyIndex != nil
    }
}

nonisolated enum CellDisplayValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Int)

    nonisolated var displayText: String {
        switch self {
        case .null:
            return "NULL"
        case .integer(let value):
            return value.formatted()
        case .real(let value):
            return value.formatted(.number)
        case .text(let value):
            return value
        case .blob(let byteCount):
            return "BLOB (\(byteCount) bytes)"
        }
    }
}

nonisolated struct TableRow: Identifiable, Hashable, Sendable {
    let id: String
    let cells: [String: CellDisplayValue]

    nonisolated func value(for columnName: String) -> CellDisplayValue {
        cells[columnName] ?? .null
    }
}

nonisolated struct TablePage: Hashable, Sendable {
    let tableName: String
    let rows: [TableRow]
    let rowCount: Int
    let pageIndex: Int
    let pageSize: Int

    nonisolated var pageStart: Int {
        rows.isEmpty ? 0 : (pageIndex * pageSize) + 1
    }

    nonisolated var pageEnd: Int {
        min(rowCount, (pageIndex * pageSize) + rows.count)
    }

    nonisolated var totalPages: Int {
        max(1, Int(ceil(Double(max(rowCount, 1)) / Double(pageSize))))
    }
}

nonisolated struct AppAlert: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}
