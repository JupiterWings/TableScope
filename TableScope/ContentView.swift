//
//  ContentView.swift
//  TableScope
//
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            DatabaseSidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } content: {
            TableListColumnView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            TableDetailView()
        }
        .frame(minWidth: 1100, minHeight: 700)
        .focusedSceneValue(
            \.openDatabaseCommandAction,
            OpenDatabaseCommandAction {
                appState.presentOpenPanel()
            }
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.presentOpenPanel()
                } label: {
                    Label("Open Database…", systemImage: "folder")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        await appState.refreshSelectedTable()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(appState.selectedTable == nil || appState.selectedSession?.isLoadingPage == true)
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { appState.isPresentingImporter },
                set: { appState.isPresentingImporter = $0 }
            ),
            allowedContentTypes: appState.importerAllowedContentTypes,
            allowsMultipleSelection: appState.importerAllowsMultipleSelection
        ) { result in
            Task {
                await appState.handleImporterResult(result: result)
            }
        } onCancellation: {
            appState.handleImporterCancellation()
        }
        .alert(
            item: Binding(
                get: { appState.alert },
                set: { appState.alert = $0 }
            )
        ) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    appState.clearAlert()
                }
            )
        }
    }
}

private struct DatabaseSidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.sessions.isEmpty {
            ContentUnavailableView {
                Label("No Databases Open", systemImage: "externaldrive.badge.questionmark")
            } description: {
                Text("Open an SQLite database to browse its tables and rows.")
            } actions: {
                Button("Open Database…") {
                    appState.presentOpenPanel()
                }
            }
            .navigationTitle("Databases")
        } else {
            List(selection: databaseSelection) {
                ForEach(appState.sessions) { session in
                    DatabaseRow(session: session)
                        .tag(session.id)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Databases")
        }
    }

    private var databaseSelection: Binding<UUID?> {
        Binding(
            get: { appState.selectedDatabaseID },
            set: { newValue in
                Task {
                    await appState.selectDatabase(id: newValue)
                }
            }
        )
    }
}

private struct DatabaseRow: View {
    @Environment(AppState.self) private var appState

    let session: DatabaseSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .lineLimit(1)
                Text(session.parentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                Task {
                    await appState.closeDatabase(id: session.id)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove Database")
        }
        .padding(.vertical, 2)
    }
}

private struct TableListColumnView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let session = appState.selectedSession {
            if session.tables.isEmpty {
                ContentUnavailableView(
                    "No User Tables",
                    systemImage: "tablecells",
                    description: Text("The selected database does not contain any user tables.")
                )
                .navigationTitle(session.displayName)
            } else {
                List(selection: tableSelection) {
                    ForEach(session.tables) { table in
                        Label(table.name, systemImage: "tablecells")
                            .tag(table.name)
                    }
                }
                .navigationTitle("Tables")
            }
        } else if appState.sessions.isEmpty {
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

    private var tableSelection: Binding<String?> {
        Binding(
            get: { appState.selectedSession?.selectedTableName },
            set: { newValue in
                Task {
                    await appState.selectTable(named: newValue)
                }
            }
        )
    }
}

private struct TableDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.sessions.isEmpty {
            ContentUnavailableView {
                Label("No Database Selected", systemImage: "internaldrive")
            } description: {
                Text("Open a database to inspect its tables and rows.")
            } actions: {
                Button("Open Database…") {
                    appState.presentOpenPanel()
                }
            }
        } else if let session = appState.selectedSession {
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
            } else if let table = appState.selectedTable, let page = session.page {
                TablePageView(table: table, page: page)
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
}

private struct TablePageView: View {
    @Environment(AppState.self) private var appState

    let table: DatabaseTable
    let page: TablePage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(of: TableRow.self) {
                TableColumnForEach(table.columns) { column in
                    TableColumn(column.name) { row in
                        Text(row.value(for: column.name).displayText)
                            .lineLimit(1)
                            .help(row.value(for: column.name).displayText)
                    }
                }
            } rows: {
                ForEach(page.rows) { row in
                    SwiftUI.TableRow(row)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Page \(page.pageIndex + 1) of \(page.totalPages)")
                        .monospacedDigit()
                    Text(rowStatusText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button("<") {
                    Task {
                        await appState.loadPreviousPage()
                    }
                }
                .disabled(!appState.canGoToPreviousPage)

                Button(">") {
                    Task {
                        await appState.loadNextPage()
                    }
                }
                .disabled(!appState.canGoToNextPage)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .padding()
    }

    private var rowStatusText: String {
        if page.rows.isEmpty {
            return "No rows to display"
        }

        return "Showing rows \(page.pageStart)-\(page.pageEnd)"
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
