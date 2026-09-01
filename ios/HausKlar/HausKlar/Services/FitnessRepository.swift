import Foundation
import GRDB

/// The only holder of FitnessRepository's raw persistence and encoding
/// dependencies. Its initializer is file-private; actor extensions can perform
/// only these narrow synchronous operations. The context must never be retained
/// or used independently of the single FitnessRepository actor facade.
struct FitnessRepositoryContext {
    private let database: FitnessDatabase
    private let injectedDeviceId: String?
    private let encoder: JSONEncoder

    fileprivate init(database: FitnessDatabase, deviceId: String?) {
        self.database = database
        injectedDeviceId = deviceId
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(FitnessDatabase.dateString(date))
        }
        self.encoder = encoder
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        try database.read(body)
    }

    func write<T>(_ body: (Database) throws -> T) throws -> T {
        try database.write(body)
    }

    func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    func verifiedDeviceId() throws -> String {
        if let injectedDeviceId { return injectedDeviceId }
        return try APIClient.shared.clientId
    }

    func activeOwnerId() -> String {
        database.activeIdentity?
            .split(separator: ":", omittingEmptySubsequences: false)
            .last
            .map(String.init)
            ?? "local-owner"
    }

    func markFirstPostMigrationSyncComplete() throws {
        try database.markFirstPostMigrationSyncComplete()
    }
}

actor FitnessRepository {
    static let shared = FitnessRepository()

    /// Internal solely so same-type extensions in other files can use the
    /// narrow context. Actor isolation prevents independent concurrent access.
    let context: FitnessRepositoryContext

    init(database: FitnessDatabase = .shared, deviceId: String? = nil) {
        context = FitnessRepositoryContext(database: database, deviceId: deviceId)
    }
}
