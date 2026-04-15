//
//  WorkspacePersistenceStoreTests.swift
//  TableScopeTests
//
//

import XCTest
@testable import TableScope

final class WorkspacePersistenceStoreTests: XCTestCase {
    func testSaveAndLoadRoundTripUsesStandardizedSources() throws {
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
        let secondSource = DatabaseSource.remoteSQLite(
            RemoteDatabaseSource(
                hostAlias: " torvalds1 ",
                databasePath: "/tmp/../tmp/sample.sqlite3"
            )
        )

        store.save(
            databaseSources: [
                .localFile(LocalFileDatabaseSource(url: firstURL)),
                secondSource
            ]
        )

        XCTAssertEqual(
            store.load(),
            PersistedWorkspaceState(
                version: PersistedWorkspaceState.currentVersion,
                databaseSources: [
                    PersistedDatabaseSource(
                        source: .localFile(
                            LocalFileDatabaseSource(
                                url: firstURL.resolvingSymlinksInPath().standardizedFileURL
                            )
                        )
                    ),
                    PersistedDatabaseSource(
                        source: .remoteSQLite(
                            RemoteDatabaseSource(
                                hostAlias: "torvalds1",
                                databasePath: "/tmp/sample.sqlite3"
                            )
                        )
                    )
                ]
            )
        )
    }

    func testLoadMigratesLegacyPathPersistence() throws {
        let suiteName = "TableScopeTests.WorkspaceStore.Legacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let legacyState = """
        {"version":1,"databasePaths":["/tmp/example.sqlite3"]}
        """.data(using: .utf8)!
        defaults.set(legacyState, forKey: "TableScopeTests.persistedWorkspaceState")

        let store = WorkspacePersistenceStore(
            defaults: defaults,
            key: "TableScopeTests.persistedWorkspaceState"
        )

        XCTAssertEqual(
            store.load(),
            PersistedWorkspaceState(
                version: PersistedWorkspaceState.currentVersion,
                databaseSources: [
                    PersistedDatabaseSource(
                        source: .localFile(
                            LocalFileDatabaseSource(
                                url: URL(fileURLWithPath: "/tmp/example.sqlite3")
                            )
                        )
                    )
                ]
            )
        )
    }
}
