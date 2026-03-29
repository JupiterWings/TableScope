//
//  SQLiteBrowserTests.swift
//  TableScopeTests
//
//

import XCTest
@testable import TableScope

final class SQLiteBrowserTests: XCTestCase {
    func testOpenDatabaseListsOnlyUserTables() async throws {
        let browser = SQLiteBrowser()
        let openedDatabase = try await browser.openDatabase(at: try fixtureURL(named: "Sample", extension: "sqlite3"))
        addTeardownBlock {
            await browser.closeDatabase(id: openedDatabase.id)
        }

        XCTAssertEqual(openedDatabase.tables.map(\.name), ["events", "people"])
        XCTAssertFalse(openedDatabase.tables.map(\.name).contains("sqlite_sequence"))
    }

    func testOpenDatabaseRejectsInvalidFile() async throws {
        let browser = SQLiteBrowser()

        do {
            _ = try await browser.openDatabase(at: try fixtureURL(named: "NotADatabase", extension: "txt"))
            XCTFail("Expected invalid fixture to fail SQLite open.")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testLoadSchemaAndFirstPage() async throws {
        let browser = SQLiteBrowser()
        let openedDatabase = try await browser.openDatabase(at: try fixtureURL(named: "Sample", extension: "sqlite3"))
        addTeardownBlock {
            await browser.closeDatabase(id: openedDatabase.id)
        }

        let loadedTable = try await browser.loadSchemaAndPage(
            for: openedDatabase.id,
            table: "people",
            pageSize: 2,
            offset: 0
        )

        XCTAssertEqual(loadedTable.table.columns.map(\.name), ["id", "name", "age", "rating", "note", "payload"])
        XCTAssertEqual(loadedTable.table.rowCount, 3)
        XCTAssertEqual(loadedTable.page.rowCount, 3)
        XCTAssertEqual(loadedTable.page.rows.count, 2)
        XCTAssertEqual(loadedTable.page.pageIndex, 0)
        XCTAssertEqual(loadedTable.page.rows[0].value(for: "name"), .text("Ada"))
        XCTAssertEqual(loadedTable.page.rows[1].value(for: "name"), .text("Grace"))
    }

    func testPagingUsesOffsets() async throws {
        let browser = SQLiteBrowser()
        let openedDatabase = try await browser.openDatabase(at: try fixtureURL(named: "Sample", extension: "sqlite3"))
        addTeardownBlock {
            await browser.closeDatabase(id: openedDatabase.id)
        }

        let firstPage = try await browser.loadSchemaAndPage(
            for: openedDatabase.id,
            table: "people",
            pageSize: 2,
            offset: 0
        )
        let secondPage = try await browser.loadSchemaAndPage(
            for: openedDatabase.id,
            table: "people",
            pageSize: 2,
            offset: 2
        )

        XCTAssertEqual(firstPage.page.rows.map { $0.value(for: "name") }, [.text("Ada"), .text("Grace")])
        XCTAssertEqual(secondPage.page.rows.map { $0.value(for: "name") }, [.text("Linus")])
        XCTAssertEqual(secondPage.page.pageIndex, 1)
    }

    func testCellDisplayMapping() async throws {
        let browser = SQLiteBrowser()
        let openedDatabase = try await browser.openDatabase(at: try fixtureURL(named: "Sample", extension: "sqlite3"))
        addTeardownBlock {
            await browser.closeDatabase(id: openedDatabase.id)
        }

        let loadedTable = try await browser.loadSchemaAndPage(
            for: openedDatabase.id,
            table: "people",
            pageSize: 3,
            offset: 0
        )

        let firstRow = loadedTable.page.rows[0]
        let secondRow = loadedTable.page.rows[1]
        let thirdRow = loadedTable.page.rows[2]

        XCTAssertEqual(firstRow.value(for: "id"), .integer(1))
        XCTAssertEqual(firstRow.value(for: "rating"), .real(4.5))
        XCTAssertEqual(firstRow.value(for: "payload"), .blob(4))
        XCTAssertEqual(secondRow.value(for: "note"), .null)
        XCTAssertEqual(thirdRow.value(for: "payload").displayText, "BLOB (0 bytes)")
    }

    func testCloseDatabaseInvalidatesConnection() async throws {
        let browser = SQLiteBrowser()
        let openedDatabase = try await browser.openDatabase(at: try fixtureURL(named: "Sample", extension: "sqlite3"))

        await browser.closeDatabase(id: openedDatabase.id)

        do {
            _ = try await browser.listTables(for: openedDatabase.id)
            XCTFail("Expected closed database connection to be unavailable.")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
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
