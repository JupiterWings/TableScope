//
//  ContentView.swift
//  TableScope
//
//

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            DatabaseSidebarView(
                sessions: appState.sessions,
                selectedDatabaseID: databaseSelection,
                onClose: closeDatabase,
                onOpen: appState.presentOpenPanel
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } content: {
            TableListColumnView(
                selectedSession: appState.selectedSession,
                hasOpenDatabases: !appState.sessions.isEmpty,
                selectedTableName: tableSelection
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            TableDetailView(
                hasOpenDatabases: !appState.sessions.isEmpty,
                selectedSession: appState.selectedSession,
                selectedTable: appState.selectedTable,
                canGoToPreviousPage: appState.canGoToPreviousPage,
                canGoToNextPage: appState.canGoToNextPage,
                onOpen: appState.presentOpenPanel,
                onPreviousPage: loadPreviousPage,
                onNextPage: loadNextPage
            )
        }
        .frame(minWidth: 1100, minHeight: 700)
        .focusedSceneValue(
            \.openDatabaseCommandAction,
            OpenDatabaseCommandAction {
                appState.presentOpenPanel()
            }
        )
        .task {
            await appState.restorePersistedSessionsIfNeeded()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.presentOpenPanel()
                } label: {
                    Label("Open Database…", systemImage: "externaldrive.fill.badge.plus")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    refreshSelectedTable()
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

    private func closeDatabase(id: UUID) {
        Task {
            await appState.closeDatabase(id: id)
        }
    }

    private func refreshSelectedTable() {
        Task {
            await appState.refreshSelectedTable()
        }
    }

    private func loadPreviousPage() {
        Task {
            await appState.loadPreviousPage()
        }
    }

    private func loadNextPage() {
        Task {
            await appState.loadNextPage()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
