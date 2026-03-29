# TableScope

TableScope is a small native macOS app for browsing SQLite databases with SwiftUI.

It uses a three-column layout:

- Left sidebar: opened databases
- Middle column: tables for the selected database
- Right column: rows for the selected table

## Features

- Native SwiftUI `NavigationSplitView`
- Read-only SQLite browsing
- Native SwiftUI `Table` for row display
- Multiple databases open in one app session
- Simple paging for large tables
- Native file importer for opening databases
- WAL-aware folder access flow for sandboxed macOS builds

## Requirements

- Latest macOS supported by the project
- Xcode with the macOS SDK

## Opening a Database

1. Launch the app in Xcode.
2. Click `Open Database…`.
3. Select a `.db` or other SQLite database file.

If the database uses SQLite WAL sidecar files such as `my.db-wal` and `my.db-shm`, TableScope may ask for access to the containing folder. That allows the app to open live WAL-backed databases inside the macOS sandbox.

## Notes

- TableScope is read-only in v1.
- It does not execute arbitrary SQL.
- Session state is not persisted across relaunches.

## Project Structure

- `TableScope/`: app source
- `TableScopeTests/`: unit tests and fixtures
- `TableScope.xcodeproj/`: Xcode project
