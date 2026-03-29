//
//  WorkspacePersistenceStore.swift
//  TableScope
//
//

import Foundation

struct PersistedWorkspaceState: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let databasePaths: [String]
}

struct WorkspacePersistenceStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "com.tablescope.persistedWorkspaceState"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> PersistedWorkspaceState? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        do {
            let state = try JSONDecoder().decode(PersistedWorkspaceState.self, from: data)
            guard state.version == PersistedWorkspaceState.currentVersion else {
                clear()
                return nil
            }

            return state
        } catch {
            clear()
            return nil
        }
    }

    func save(databaseURLs: [URL]) {
        let state = PersistedWorkspaceState(
            version: PersistedWorkspaceState.currentVersion,
            databasePaths: databaseURLs.map {
                $0.resolvingSymlinksInPath().standardizedFileURL.path
            }
        )

        guard let data = try? JSONEncoder().encode(state) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
