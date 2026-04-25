import GRDB

enum PersistenceDependencies {
    static let packageName = "GRDB.swift"
    typealias Database = DatabaseQueue
}
