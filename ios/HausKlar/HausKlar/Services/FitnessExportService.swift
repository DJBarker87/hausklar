import Foundation
import os
import UIKit
import UniformTypeIdentifiers

enum FitnessExportServiceError: LocalizedError {
    case invalidArchive

    var errorDescription: String? {
        "The fitness export was not a valid ZIP archive."
    }
}

enum FitnessStrengthTextExport {
    static func copy(_ text: String, pasteboard: UIPasteboard = .general, now: Date = Date()) {
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: now.addingTimeInterval(15 * 60)]
        )
    }

    static func text(session: FitnessStrengthSession, exercises: [FitnessWorkoutExercise]) -> String {
        let iso=ISO8601DateFormatter()
        let duration=session.endedAt.map { clock(Int($0.timeIntervalSince(session.startedAt))) }
        let performedSets=exercises.flatMap(\.groups).filter { [.completed,.partial].contains($0.group.status) }.count
        var lines=[
            "Strength workout: \(session.title)",
            "Started: \(iso.string(from: session.startedAt))",
            "Ended: \(session.endedAt.map(iso.string(from:)) ?? "in progress")",
        ]
        if let duration { lines.append("Duration: \(duration)") }
        lines.append("Status: \(session.status.rawValue)")
        if let rpe=session.sessionRPE { lines.append("Session RPE: \(rpe.formatted())") }
        lines.append("Summary: \(exercises.count) exercises, \(performedSets) performed sets")
        for (exerciseIndex, workout) in exercises.enumerated() {
            lines.append("")
            lines.append("\(exerciseIndex+1). \(workout.exercise.exerciseName) (\(workout.exercise.setupName))")
            let groups=workout.groups.filter { $0.group.status != .planned }
            if groups.isEmpty { lines.append("   No performed sets recorded.") }
            for (groupIndex, workoutGroup) in groups.enumerated() {
                let components=workoutGroup.components.filter { $0.status != .skipped }
                let work=components.isEmpty ? workoutGroup.group.status.title : components.map(componentText).joined(separator: "; ")
                var detail="   Set \(groupIndex+1): \(work)"
                if ![.none,.unknown].contains(workoutGroup.group.failureState) {
                    detail += " | Failure: \(workoutGroup.group.failureState.title)"
                }
                if let start=workoutGroup.group.startedAt,let end=workoutGroup.group.completedAt {
                    detail += " | Set time: \(clock(Int(end.timeIntervalSince(start))))"
                }
                lines.append(detail)
            }
        }
        if let note=session.note?.trimmingCharacters(in: .whitespacesAndNewlines),!note.isEmpty {
            lines += ["", "Workout notes: \(note)"]
        }
        return lines.joined(separator: "\n")
    }

    private static func componentText(_ component: FitnessSetComponent) -> String {
        var parts:[String]=[]
        if let load=component.loadValue { parts.append("\(load.formatted()) \(component.loadUnit ?? "kg")") }
        if let reps=component.reps { parts.append("\(reps) reps") }
        else if component.repsLeft != nil || component.repsRight != nil {
            parts.append("\(component.repsLeft.map(String.init) ?? "?")/\(component.repsRight.map(String.init) ?? "?") reps left/right")
        } else if let duration=component.durationSeconds { parts.append(clock(duration)) }
        if let rir=component.rir { parts.append("RIR \(rir.formatted())") }
        else if let rpe=component.rpe { parts.append("RPE \(rpe.formatted())") }
        return parts.isEmpty ? component.status.title : parts.joined(separator: " × ")
    }

    private static func clock(_ rawSeconds: Int) -> String {
        let seconds=max(0,rawSeconds),hours=max(0,rawSeconds)/3600
        let minutes=(seconds%3600)/60,remainder=seconds%60
        return hours > 0
            ? String(format: "%d:%02d:%02d",hours,minutes,remainder)
            : String(format: "%d:%02d",minutes,remainder)
    }
}

actor FitnessExportService {
    static let shared = FitnessExportService()
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "FitnessExportService"
    )

    private let apiClient: APIClient
    private let fileManager: FileManager
    private var exportedURLs: Set<URL> = []

    init(apiClient: APIClient = .shared,fileManager: FileManager = .default) {
        self.apiClient=apiClient
        self.fileManager=fileManager
    }

    func createExport(now: Date = Date(),calendar: Calendar = .current) async throws -> URL {
        let formatter=DateFormatter()
        formatter.calendar=calendar
        formatter.locale=Locale(identifier: "en_US_POSIX")
        formatter.timeZone=calendar.timeZone
        formatter.dateFormat="yyyy-MM-dd"
        let filename="hausklar-fitness-export-\(formatter.string(from: now)).zip"
        let url=try await apiClient.downloadToTemporaryFile(
            "/fitness/export",
            filename: filename,
            maximumBytes: 250 * 1_024 * 1_024,
            allowedMediaTypes: [
                "application/zip",
                "application/x-zip-compressed",
            ],
            fileManager: FileManager()
        )
        try Self.validateZIPOrRemoveTransfer(at: url, fileManager: fileManager)
        exportedURLs.insert(url)
        return url
    }

    /// MIME is only a declaration. Verify one of the ZIP signatures that can
    /// legitimately begin a normal, empty, or spanning archive before exposing
    /// the file, and reclaim the API-owned transfer directory on any failure.
    static func validateZIPOrRemoveTransfer(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        do {
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let byteCount = values.fileSize,
                  byteCount >= 4 else {
                throw FitnessExportServiceError.invalidArchive
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer {
                do {
                    try handle.close()
                } catch {
                    Self.logger.error(
                        "Failed to close a validated fitness export: \(error.localizedDescription)"
                    )
                }
            }
            guard let prefix = try handle.read(upToCount: 4),
                  [
                      Data([0x50, 0x4B, 0x03, 0x04]),
                      Data([0x50, 0x4B, 0x05, 0x06]),
                      Data([0x50, 0x4B, 0x07, 0x08]),
                  ].contains(prefix) else {
                throw FitnessExportServiceError.invalidArchive
            }
        } catch {
            do {
                try fileManager.removeItem(at: url.deletingLastPathComponent())
            } catch let cleanupError {
                Self.logger.error(
                    "Failed to reclaim an invalid fitness export; the bounded transfer reconciler will retry: \(cleanupError.localizedDescription)"
                )
            }
            if error is FitnessExportServiceError { throw error }
            throw FitnessExportServiceError.invalidArchive
        }
    }

    func cleanup(_ url: URL) {
        guard exportedURLs.remove(url) != nil else { return }
        removeExportDirectoryBestEffort(url.deletingLastPathComponent())
    }

    func cleanupAll() {
        for url in exportedURLs {
            removeExportDirectoryBestEffort(url.deletingLastPathComponent())
        }
        exportedURLs.removeAll()
    }

    /// Export directories contain derived share artifacts only. A failed delete
    /// remains inside APIClient's bounded transfer root and is retried by its
    /// interruption reconciler on the next process launch.
    private func removeExportDirectoryBestEffort(_ directory: URL) {
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            Self.logger.error(
                "Failed to remove a fitness export; the bounded transfer reconciler will retry: \(error.localizedDescription)"
            )
        }
    }
}
