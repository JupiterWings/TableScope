//
//  SQLiteModels.swift
//  TableScope
//
//

import Foundation

nonisolated struct DatabaseSession: Identifiable, Hashable, Sendable {
    let id: UUID
    let source: DatabaseSource
    var tables: [DatabaseTable]
    var selectedTableName: String?
    var currentPageIndex: Int
    var page: TablePage?
    var isLoadingPage: Bool
    var lastErrorMessage: String?

    nonisolated var displayName: String {
        source.displayName
    }

    nonisolated var parentPath: String {
        source.parentPath
    }

    nonisolated var isRemote: Bool {
        source.isRemote
    }
}

nonisolated struct DatabaseTable: Identifiable, Hashable, Sendable, Codable {
    let name: String
    var columns: [TableColumnInfo]
    var rowCount: Int

    nonisolated var id: String {
        name
    }
}

nonisolated struct TableColumnInfo: Identifiable, Hashable, Sendable, Codable {
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

nonisolated enum CellDisplayValue: Hashable, Sendable, Codable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Int)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case byteCount
    }

    private enum Kind: String, Codable {
        case null
        case integer
        case real
        case text
        case blob
    }

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .null:
            self = .null
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case .real:
            self = .real(try container.decode(Double.self, forKey: .value))
        case .text:
            self = .text(try container.decode(String.self, forKey: .value))
        case .blob:
            self = .blob(try container.decode(Int.self, forKey: .byteCount))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .null:
            try container.encode(Kind.null, forKey: .kind)
        case .integer(let value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .real(let value):
            try container.encode(Kind.real, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .blob(let byteCount):
            try container.encode(Kind.blob, forKey: .kind)
            try container.encode(byteCount, forKey: .byteCount)
        }
    }
}

nonisolated struct TableRow: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let cells: [String: CellDisplayValue]

    nonisolated func value(for columnName: String) -> CellDisplayValue {
        cells[columnName] ?? .null
    }
}

nonisolated struct TablePage: Hashable, Sendable, Codable {
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
