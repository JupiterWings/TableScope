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

private struct OpenDatabaseCommandActionKey: FocusedValueKey {
    typealias Value = OpenDatabaseCommandAction
}

extension FocusedValues {
    var openDatabaseCommandAction: OpenDatabaseCommandAction? {
        get { self[OpenDatabaseCommandActionKey.self] }
        set { self[OpenDatabaseCommandActionKey.self] = newValue }
    }
}
