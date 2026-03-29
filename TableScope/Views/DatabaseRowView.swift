//
//  DatabaseRowView.swift
//  TableScope
//
//

import SwiftUI

struct DatabaseRowView: View {
    let session: DatabaseSession
    let onClose: () -> Void

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
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove Database")
        }
        .padding(.vertical, 2)
    }
}
