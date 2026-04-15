//
//  OpenDatabaseCommandContext.swift
//  TableScope
//
//

import SwiftUI

struct OpenDatabaseCommandAction {
    let perform: () -> Void

    func callAsFunction() {
        perform()
    }
}

struct OpenRemoteDatabaseCommandAction {
    let perform: () -> Void

    func callAsFunction() {
        perform()
    }
}

private struct OpenDatabaseCommandActionKey: FocusedValueKey {
    typealias Value = OpenDatabaseCommandAction
}

private struct OpenRemoteDatabaseCommandActionKey: FocusedValueKey {
    typealias Value = OpenRemoteDatabaseCommandAction
}

extension FocusedValues {
    var openDatabaseCommandAction: OpenDatabaseCommandAction? {
        get { self[OpenDatabaseCommandActionKey.self] }
        set { self[OpenDatabaseCommandActionKey.self] = newValue }
    }

    var openRemoteDatabaseCommandAction: OpenRemoteDatabaseCommandAction? {
        get { self[OpenRemoteDatabaseCommandActionKey.self] }
        set { self[OpenRemoteDatabaseCommandActionKey.self] = newValue }
    }
}
