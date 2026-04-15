//
//  RemoteDatabaseSheet.swift
//  TableScope
//
//

import SwiftUI

struct RemoteDatabaseSheet: View {
    let hostAlias: Binding<String>
    let databasePath: Binding<String>
    let onCancel: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Open Remote Database")
                .font(.title3.weight(.semibold))

            Text("Connect to a remote SQLite database over SSH using the helper installed on the remote host.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                TextField("SSH Host Alias", text: hostAlias)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                TextField("Remote Database Path", text: databasePath)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)

                Button("Open", action: onOpen)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
