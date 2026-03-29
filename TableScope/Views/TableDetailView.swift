//
//  TableDetailView.swift
//  TableScope
//
//

import SwiftUI

struct TableDetailView: View {
    let hasOpenDatabases: Bool
    let selectedSession: DatabaseSession?
    let selectedTable: DatabaseTable?
    let canGoToPreviousPage: Bool
    let canGoToNextPage: Bool
    let onOpen: () -> Void
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void

    var body: some View {
        if !hasOpenDatabases {
            ContentUnavailableView {
                Label("No Database Selected", systemImage: "internaldrive")
            } description: {
                Text("Open a database to inspect its tables and rows.")
            } actions: {
                Button("Open Database…", action: onOpen)
            }
        } else if let session = selectedSession {
            if session.tables.isEmpty {
                ContentUnavailableView(
                    "No Tables to Display",
                    systemImage: "tablecells",
                    description: Text("The selected database does not contain any user tables.")
                )
            } else if session.isLoadingPage {
                ProgressView("Loading \(session.selectedTableName ?? "Table")…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = session.lastErrorMessage {
                ContentUnavailableView(
                    "Couldn’t Load Table",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if let selectedTable, let page = session.page {
                TablePageView(
                    table: selectedTable,
                    page: page,
                    canGoToPreviousPage: canGoToPreviousPage,
                    canGoToNextPage: canGoToNextPage,
                    onPreviousPage: onPreviousPage,
                    onNextPage: onNextPage
                )
                .id(tableViewIdentity(sessionID: session.id, table: selectedTable))
            } else {
                ContentUnavailableView(
                    "Select a Table",
                    systemImage: "tablecells.badge.ellipsis",
                    description: Text("Choose a table from the middle column to preview its rows.")
                )
            }
        } else {
            ContentUnavailableView(
                "Select a Database",
                systemImage: "sidebar.left",
                description: Text("Choose a database from the sidebar.")
            )
        }
    }

    private func tableViewIdentity(sessionID: UUID, table: DatabaseTable) -> String {
        let columnNames = table.columns.map(\.name).joined(separator: "|")
        return "\(sessionID.uuidString):\(table.name):\(columnNames)"
    }
}
