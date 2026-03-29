//
//  WorkspacePersistenceStoreTests.swift
//  TableScopeTests
//
//

import XCTest
@testable import TableScope

final class WorkspacePersistenceStoreTests: XCTestCase {
    func testSaveAndLoadRoundTripUsesStandardizedAbsolutePaths() throws {
        let suiteName = "TableScopeTests.WorkspaceStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = WorkspacePersistenceStore(
            defaults: defaults,
            key: "TableScopeTests.persistedWorkspaceState"
        )
        let firstURL = URL(fileURLWithPath: "/tmp/../tmp/example.sqlite3")
        let secondURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nested")
            .appendingPathComponent("sample.sqlite3")

        store.save(databaseURLs: [firstURL, secondURL])

        XCTAssertEqual(
            store.load(),
            PersistedWorkspaceState(
                version: PersistedWorkspaceState.currentVersion,
                databasePaths: [
                    firstURL.resolvingSymlinksInPath().standardizedFileURL.path,
                    secondURL.resolvingSymlinksInPath().standardizedFileURL.path
                ]
            )
        )
    }
}
