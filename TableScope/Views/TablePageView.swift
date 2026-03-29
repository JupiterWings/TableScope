//
//  TablePageView.swift
//  TableScope
//
//

import SwiftUI

struct TablePageView: View {
    let table: DatabaseTable
    let page: TablePage
    let canGoToPreviousPage: Bool
    let canGoToNextPage: Bool
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void

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

                Button("<", action: onPreviousPage)
                    .disabled(!canGoToPreviousPage)

                Button(">", action: onNextPage)
                    .disabled(!canGoToNextPage)
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
