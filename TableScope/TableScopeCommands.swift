//
//  TableScopeCommands.swift
//  TableScope
//
//

import SwiftUI

struct TableScopeCommands: Commands {
    @FocusedValue(\.openDatabaseCommandAction) private var openDatabaseCommandAction

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()

            Button("Open Database…") {
                openDatabaseCommandAction?()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(openDatabaseCommandAction == nil)
        }
    }
}
