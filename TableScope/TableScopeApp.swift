//
//  TableScopeApp.swift
//  TableScope
//
//

import SwiftUI

@main
struct TableScopeApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        .commands {
            TableScopeCommands()
        }
    }
}
