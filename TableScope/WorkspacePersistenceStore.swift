//
//  WorkspacePersistenceStore.swift
//  TableScope
//
//

import Foundation

nonisolated struct PersistedDatabaseSource: Codable, Equatable {
    enum Kind: String, Codable {
        case localFile
        case remoteSQLite
    }

    let kind: Kind
    let path: String?
    let hostAlias: String?
    let remotePath: String?

    nonisolated init(source: DatabaseSource) {
        switch source.normalized {
        case .localFile(let localSource):
            self.kind = .localFile
            self.path = localSource.url.path
            self.hostAlias = nil
            self.remotePath = nil
        case .remoteSQLite(let remoteSource):
            self.kind = .remoteSQLite
            self.path = nil
            self.hostAlias = remoteSource.hostAlias
            self.remotePath = remoteSource.databasePath
        }
    }

    nonisolated var databaseSource: DatabaseSource? {
        switch kind {
        case .localFile:
            guard let path else {
                return nil
            }

            return .localFile(LocalFileDatabaseSource(url: URL(fileURLWithPath: path, isDirectory: false)))
        case .remoteSQLite:
            guard let hostAlias, let remotePath else {
                return nil
            }

            return .remoteSQLite(
                RemoteDatabaseSource(
                    hostAlias: hostAlias,
                    databasePath: remotePath
                )
            )
        }
    }
}

nonisolated struct PersistedWorkspaceState: Codable, Equatable {
    nonisolated static let currentVersion = 2

    let version: Int
    let databaseSources: [PersistedDatabaseSource]
}

private nonisolated struct LegacyPersistedWorkspaceState: Codable {
    let version: Int
    let databasePaths: [String]
}

nonisolated struct WorkspacePersistenceStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "com.tablescope.persistedWorkspaceState"
    ) {
        self.defaults = defaults
        self.key = key
    }

    nonisolated func load() -> PersistedWorkspaceState? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        let decoder = JSONDecoder()

        if let state = try? decoder.decode(PersistedWorkspaceState.self, from: data) {
            guard state.version == PersistedWorkspaceState.currentVersion else {
                clear()
                return nil
            }

            return state
        }

        if let legacyState = try? decoder.decode(LegacyPersistedWorkspaceState.self, from: data),
           legacyState.version == 1 {
            return PersistedWorkspaceState(
                version: PersistedWorkspaceState.currentVersion,
                databaseSources: legacyState.databasePaths.map {
                    PersistedDatabaseSource(
                        source: .localFile(
                            LocalFileDatabaseSource(
                                url: URL(fileURLWithPath: $0, isDirectory: false)
                            )
                        )
                    )
                }
            )
        }

        clear()
        return nil
    }

    nonisolated func save(databaseSources: [DatabaseSource]) {
        let state = PersistedWorkspaceState(
            version: PersistedWorkspaceState.currentVersion,
            databaseSources: databaseSources.map(PersistedDatabaseSource.init(source:))
        )

        guard let data = try? JSONEncoder().encode(state) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    nonisolated func clear() {
        defaults.removeObject(forKey: key)
    }
}
