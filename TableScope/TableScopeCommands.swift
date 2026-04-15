//
//  TableScopeCommands.swift
//  TableScope
//
//

import SwiftUI

struct TableScopeCommands: Commands {
    @FocusedValue(\.openDatabaseCommandAction) private var openDatabaseCommandAction
    @FocusedValue(\.openRemoteDatabaseCommandAction) private var openRemoteDatabaseCommandAction

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()

            Button("Open Database…") {
                openDatabaseCommandAction?()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(openDatabaseCommandAction == nil)

            Button("Open Remote Database…") {
                openRemoteDatabaseCommandAction?()
            }
            .keyboardShortcut("O", modifiers: [.command, .shift])
            .disabled(openRemoteDatabaseCommandAction == nil)
        }
    }
}
