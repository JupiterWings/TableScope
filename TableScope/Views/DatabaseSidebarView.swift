//
//  DatabaseSidebarView.swift
//  TableScope
//
//

import SwiftUI

struct DatabaseSidebarView: View {
    let sessions: [DatabaseSession]
    let selectedDatabaseID: Binding<UUID?>
    let onClose: (UUID) -> Void
    let onOpen: () -> Void

    var body: some View {
        if sessions.isEmpty {
            ContentUnavailableView {
                Label("No Databases Open", systemImage: "externaldrive.badge.questionmark")
            } description: {
                Text("Open an SQLite database to browse its tables and rows.")
            } actions: {
                Button("Open Database…", action: onOpen)
            }
            .navigationTitle("Databases")
        } else {
            List(selection: selectedDatabaseID) {
                ForEach(sessions) { session in
                    DatabaseRowView(session: session) {
                        onClose(session.id)
                    }
                    .tag(session.id)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Databases")
        }
    }
}
