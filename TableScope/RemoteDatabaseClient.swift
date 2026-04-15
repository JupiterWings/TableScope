//
//  RemoteDatabaseClient.swift
//  TableScope
//
//

import Foundation

nonisolated struct RemoteHelperConfiguration {
    nonisolated static let defaultHostAlias = "torvalds1"
    nonisolated static let defaultRoot = "$HOME/Documents/GitHub/TableScope-RemoteHelper"
}

nonisolated struct RemoteDatabaseOpenResponse: Codable, Hashable, Sendable {
    let sessionID: String
    let tables: [DatabaseTable]

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case tables
    }
}

nonisolated struct RemoteDatabasePageResponse: Codable, Hashable, Sendable {
    let table: DatabaseTable
    let page: TablePage
}

protocol RemoteDatabaseClient: Sendable {
    func openDatabase(at path: String) async throws -> RemoteDatabaseOpenResponse
    func listTables(sessionID: String) async throws -> [DatabaseTable]
    func loadSchemaAndPage(
        sessionID: String,
        tableName: String,
        pageSize: Int,
        offset: Int
    ) async throws -> RemoteDatabasePageResponse
    func refreshPage(
        sessionID: String,
        tableName: String,
        pageSize: Int,
        offset: Int
    ) async throws -> RemoteDatabasePageResponse
    func closeDatabase(sessionID: String) async
    func shutdown() async
}

nonisolated struct RemoteProtocolError: Decodable, Error, LocalizedError, Sendable {
    let code: String
    let message: String

    var errorDescription: String? {
        message
    }
}

actor SSHRemoteDatabaseClient: RemoteDatabaseClient {
    private enum ClientError: LocalizedError {
        case invalidResponse
        case missingResult
        case responseIDMismatch(expected: String, actual: String)
        case unexpectedEOF(details: String?)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The remote helper returned an invalid response."
            case .missingResult:
                return "The remote helper returned an empty response."
            case .responseIDMismatch(let expected, let actual):
                return "The remote helper response ID \(actual) did not match request \(expected)."
            case .unexpectedEOF(let details):
                if let details, !details.isEmpty {
                    return "The remote helper connection closed unexpectedly. \(details)"
                }

                return "The remote helper connection closed unexpectedly."
            }
        }
    }

    private struct RequestEnvelope<Params: Encodable>: Encodable {
        let id: String
        let method: String
        let params: Params
    }

    private struct ResponseEnvelope<Result: Decodable>: Decodable {
        let id: String
        let result: Result?
        let error: RemoteProtocolError?
    }

    private struct EmptyParams: Encodable {}

    private struct OpenParams: Encodable {
        let path: String
    }

    private struct SessionParams: Encodable {
        let sessionID: String

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
        }
    }

    private struct LoadPageParams: Encodable {
        let sessionID: String
        let table: String
        let pageSize: Int
        let offset: Int

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case table
            case pageSize = "page_size"
            case offset
        }
    }

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private var stdoutBuffer = Data()
    private var requestCounter = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        hostAlias: String,
        helperRoot: String = RemoteHelperConfiguration.defaultRoot
    ) async throws {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T",
            hostAlias,
            "bash",
            "-lc",
            Self.remoteCommand(helperRoot: helperRoot)
        ]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
    }

    func openDatabase(at path: String) async throws -> RemoteDatabaseOpenResponse {
        try await send(
            method: "open",
            params: OpenParams(path: path),
            responseType: RemoteDatabaseOpenResponse.self
        )
    }

    func listTables(sessionID: String) async throws -> [DatabaseTable] {
        struct ListTablesResponse: Decodable {
            let tables: [DatabaseTable]
        }

        let response = try await send(
            method: "list_tables",
            params: SessionParams(sessionID: sessionID),
            responseType: ListTablesResponse.self
        )

        return response.tables
    }

    func loadSchemaAndPage(
        sessionID: String,
        tableName: String,
        pageSize: Int,
        offset: Int
    ) async throws -> RemoteDatabasePageResponse {
        try await send(
            method: "load_schema_and_page",
            params: LoadPageParams(
                sessionID: sessionID,
                table: tableName,
                pageSize: pageSize,
                offset: offset
            ),
            responseType: RemoteDatabasePageResponse.self
        )
    }

    func refreshPage(
        sessionID: String,
        tableName: String,
        pageSize: Int,
        offset: Int
    ) async throws -> RemoteDatabasePageResponse {
        try await send(
            method: "refresh_page",
            params: LoadPageParams(
                sessionID: sessionID,
                table: tableName,
                pageSize: pageSize,
                offset: offset
            ),
            responseType: RemoteDatabasePageResponse.self
        )
    }

    func closeDatabase(sessionID: String) async {
        _ = try? await send(
            method: "close",
            params: SessionParams(sessionID: sessionID),
            responseType: EmptyResponse.self
        )
    }

    func shutdown() async {
        try? stdinHandle.close()

        guard process.isRunning else {
            return
        }

        process.terminate()
    }

    private func send<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params,
        responseType: Result.Type
    ) async throws -> Result {
        guard process.isRunning else {
            let details = try await terminationDetails()
            throw ClientError.unexpectedEOF(details: details)
        }

        requestCounter += 1
        let requestID = String(requestCounter)
        let envelope = RequestEnvelope(id: requestID, method: method, params: params)
        var data = try encoder.encode(envelope)
        data.append(0x0A)

        try await write(data)
        let line = try await readResponseLine()
        let responseData = Data(line.utf8)
        let envelopeResponse = try decoder.decode(ResponseEnvelope<Result>.self, from: responseData)

        guard envelopeResponse.id == requestID else {
            throw ClientError.responseIDMismatch(expected: requestID, actual: envelopeResponse.id)
        }

        if let error = envelopeResponse.error {
            throw error
        }

        guard let result = envelopeResponse.result else {
            throw ClientError.missingResult
        }

        return result
    }

    private func write(_ data: Data) async throws {
        let stdinHandle = self.stdinHandle
        try await Task.detached {
            try stdinHandle.write(contentsOf: data)
        }.value
    }

    private func readResponseLine() async throws -> String {
        while true {
            if let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
                let lineData = stdoutBuffer[..<newlineIndex]
                stdoutBuffer.removeSubrange(...newlineIndex)
                return String(decoding: lineData, as: UTF8.self)
            }

            let chunk = try await readChunk()
            guard !chunk.isEmpty else {
                let details = try await terminationDetails()
                throw ClientError.unexpectedEOF(details: details)
            }

            stdoutBuffer.append(chunk)
        }
    }

    private func readChunk() async throws -> Data {
        let stdoutHandle = self.stdoutHandle
        return await Task.detached {
            stdoutHandle.availableData
        }.value
    }

    private func terminationDetails() async throws -> String? {
        let process = self.process
        let stderrHandle = self.stderrHandle
        let stderrData = try await Task.detached {
            try stderrHandle.readToEnd() ?? Data()
        }.value

        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let exitSummary: String
        if process.isRunning {
            exitSummary = "The SSH process is still running without producing output."
        } else {
            exitSummary = "SSH exited with status \(process.terminationStatus)."
        }

        if let stderrText, !stderrText.isEmpty {
            return "\(exitSummary) \(stderrText)"
        }

        return exitSummary
    }

    nonisolated private static func remoteCommand(helperRoot: String) -> String {
        let escapedRoot = helperRoot
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let command = "cd \"\(escapedRoot)\" && exec python3 -m tablescope_remote_helper"
        return shellSingleQuoted(command)
    }

    nonisolated private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private struct EmptyResponse: Decodable {}
