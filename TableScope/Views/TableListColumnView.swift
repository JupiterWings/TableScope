//
//  TableListColumnView.swift
//  TableScope
//
//

import SwiftUI

struct TableListColumnView: View {
    let selectedSession: DatabaseSession?
    let hasOpenDatabases: Bool
    let selectedTableName: Binding<String?>

    var body: some View {
        if let session = selectedSession {
            if session.tables.isEmpty {
                ContentUnavailableView(
                    "No User Tables",
                    systemImage: "tablecells",
                    description: Text("The selected database does not contain any user tables.")
                )
                .navigationTitle(session.displayName)
            } else {
                List(selection: selectedTableName) {
                    ForEach(session.tables) { table in
                        Label(table.name, systemImage: "tablecells")
                            .tag(table.name)
                    }
                }
                .navigationTitle(session.displayName)
            }
        } else if !hasOpenDatabases {
            ContentUnavailableView(
                "Open a Database",
                systemImage: "sidebar.left",
                description: Text("Opened databases appear in the sidebar.")
            )
            .navigationTitle("Tables")
        } else {
            ContentUnavailableView(
                "Select a Database",
                systemImage: "externaldrive",
                description: Text("Choose a database from the sidebar to see its tables.")
            )
            .navigationTitle("Tables")
        }
    }
}
