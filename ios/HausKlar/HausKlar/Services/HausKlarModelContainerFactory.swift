import Combine
import Foundation
import SwiftData
import os

enum PersistentStoreBootstrapStage: String, Equatable {
    case initialProtection
    case recovery
    case finalProtection
}

struct PersistentStoreBootstrapFailure: LocalizedError {
    let stage: PersistentStoreBootstrapStage
    let initialErrorDescription: String
    let terminalErrorDescription: String

    var errorDescription: String? {
        switch stage {
        case .initialProtection:
            return "The local store could not be protected: \(terminalErrorDescription)"
        case .recovery:
            return "The local store could not be opened (\(initialErrorDescription)) or recovered (\(terminalErrorDescription))."
        case .finalProtection:
            return "The opened local store could not be protected: \(terminalErrorDescription)"
        }
    }
}

enum PersistentStoreBootstrapResult<Container> {
    case ready(container: Container, recovered: Bool, archiveURL: URL?)
    case failed(PersistentStoreBootstrapFailure)

    var container: Container? {
        guard case .ready(let container, _, _) = self else { return nil }
        return container
    }
}

/// A small injectable state machine that makes durable storage a prerequisite
/// for application activation. There is deliberately no volatile fallback:
/// callers receive no container after any terminal recovery or protection
/// failure, so successful-looking medicine/offline writes cannot disappear on
/// process termination.
enum PersistentStoreBootstrap {
    static func run<Container>(
        storeURL: URL,
        protect: (URL) throws -> Void,
        openPersistent: () throws -> Container,
        archive: (URL) throws -> URL,
        markRecovered: () -> Void
    ) -> PersistentStoreBootstrapResult<Container> {
        do {
            try protect(storeURL)
        } catch {
            return .failed(
                PersistentStoreBootstrapFailure(
                    stage: .initialProtection,
                    initialErrorDescription: error.localizedDescription,
                    terminalErrorDescription: error.localizedDescription
                )
            )
        }

        let initialContainer: Container
        do {
            initialContainer = try openPersistent()
        } catch {
            let initialError = error
            do {
                let archiveURL = try archive(storeURL)
                let recoveredContainer = try openPersistent()
                try protect(storeURL)
                markRecovered()
                return .ready(
                    container: recoveredContainer,
                    recovered: true,
                    archiveURL: archiveURL
                )
            } catch {
                return .failed(
                    PersistentStoreBootstrapFailure(
                        stage: .recovery,
                        initialErrorDescription: initialError.localizedDescription,
                        terminalErrorDescription: error.localizedDescription
                    )
                )
            }
        }

        do {
            try protect(storeURL)
            return .ready(container: initialContainer, recovered: false, archiveURL: nil)
        } catch {
            return .failed(
                PersistentStoreBootstrapFailure(
                    stage: .finalProtection,
                    initialErrorDescription: error.localizedDescription,
                    terminalErrorDescription: error.localizedDescription
                )
            )
        }
    }
}

enum HausKlarModelContainerFactory {
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "ModelContainer"
    )

    static func make() -> PersistentStoreBootstrapResult<ModelContainer> {
        let schema = Schema(versionedSchema: HausKlarSchemaV5.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let result = PersistentStoreBootstrap.run(
            storeURL: configuration.url,
            protect: { try LocalFileProtection.protectSQLiteStore(at: $0) },
            openPersistent: {
                try ModelContainer(
                    for: schema,
                    migrationPlan: HausKlarMigrationPlan.self,
                    configurations: [configuration]
                )
            },
            archive: { try LocalStoreRecovery.archiveStore(at: $0) },
            markRecovered: {
                UserDefaults.standard.set(true, forKey: LocalStoreRecovery.recoveryFlag)
            }
        )

        switch result {
        case .ready(_, let recovered, let archiveURL):
            if recovered, let archiveURL {
                logger.error("Recovered persistent local store; archive: \(archiveURL.path, privacy: .private)")
            }
        case .failed(let failure):
            logger.error("Persistent local storage unavailable: \(failure.localizedDescription, privacy: .private)")
        }
        return result
    }
}

/// Keeps the generic bootstrap result's unchecked transfer private and
/// immutable. SwiftData declares `ModelContainer` as unchecked Sendable; all
/// later model-context access still happens through SwiftUI's main actor.
private struct ModelContainerBootstrapTransfer: @unchecked Sendable {
    let result: PersistentStoreBootstrapResult<ModelContainer>
}

/// Opens and verifies the durable store without holding up the first frame.
/// The task is single-flight and deliberately allowed to finish if the view task
/// is cancelled, avoiding concurrent recovery attempts against the same files.
@MainActor
final class HausKlarModelContainerLoader: ObservableObject {
    @Published private(set) var result: PersistentStoreBootstrapResult<ModelContainer>?
    private var bootstrapTask: Task<ModelContainerBootstrapTransfer, Never>?

    func load() async {
        guard result == nil else { return }
        let task: Task<ModelContainerBootstrapTransfer, Never>
        if let bootstrapTask {
            task = bootstrapTask
        } else {
            task = Task.detached(priority: .userInitiated) {
                ModelContainerBootstrapTransfer(
                    result: HausKlarModelContainerFactory.make()
                )
            }
            bootstrapTask = task
        }

        let transfer = await task.value
        guard result == nil else { return }
        result = transfer.result
        bootstrapTask = nil
    }
}
