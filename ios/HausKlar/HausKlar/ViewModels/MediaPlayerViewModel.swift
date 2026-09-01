import Combine
import Foundation
import os

/// View model for Sonos/media player controls, extracted from HomeViewModel.
/// Handles play/pause, next/prev, volume, shuffle, repeat, mute, and media playback.
@MainActor
final class MediaPlayerViewModel: ObservableObject {

    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "MediaPlayerViewModel"
    )

    // MARK: - Published State

    @Published var sonosPlayers: [SonosPlayer] = []

    // Toast feedback (shared with parent for overlay display)
    @Published var toastMessage: String?
    @Published var toastIsWarning: Bool = false

    let haClient: HAClient

    init(haClient: HAClient) {
        self.haClient = haClient
    }

    // MARK: - Data Structures

    struct SonosPlayer: Identifiable {
        let id: String
        let name: String
        let state: String
        let mediaTitle: String?
        let mediaArtist: String?
    }

    // MARK: - Derived State

    /// Sonos now-playing summary for the status banner, or nil if nothing is playing.
    var statusSonosSummary: String? {
        let playing = sonosPlayers.first(where: { $0.state == "playing" })
        if let playing {
            return "\u{266A} \(playing.mediaTitle ?? playing.name)"
        }
        return nil
    }

    // MARK: - Compute from Entities

    func computeSonosPlayers() {
        computeSonosPlayers(from: haClient.entities(inDomain: "media_player"))
    }

    func computeSonosPlayers(from mediaPlayers: [HAEntity]) {
        sonosPlayers = mediaPlayers
            .filter { $0.entityId.contains("sonos") }
            .map { entity in
                SonosPlayer(
                    id: entity.entityId,
                    name: entity.friendlyName,
                    state: entity.state,
                    mediaTitle: entity.mediaTitle,
                    mediaArtist: entity.mediaArtist
                )
            }
    }

    // MARK: - Actions

    /// Perform an HA service call with optional optimistic UI update.
    private func performAction(
        domain: String, service: String, data: [String: Any],
        optimisticUpdate: (() -> Void)? = nil
    ) async {
        optimisticUpdate?()
        do {
            try await haClient.callService(domain: domain, service: service, data: data)
        } catch {
            // Error is non-fatal for media controls
        }
        haClient.scheduleBackgroundRefresh()
    }

    /// Toggle play/pause on a media player.
    func mediaPlayPause(_ entityId: String) async {
        let currentState = haClient.entity(entityId)?.state
        let newState = currentState == "playing" ? "paused" : "playing"
        await performAction(domain: "media_player", service: "media_play_pause", data: ["entity_id": entityId]) { [self] in
            haClient.updateEntityOptimistically(entityId, state: newState)
        }
    }

    /// Skip to next track.
    func mediaNext(_ entityId: String) async {
        await performAction(domain: "media_player", service: "media_next_track", data: ["entity_id": entityId]) { [self] in
            haClient.updateEntityOptimistically(entityId, attributeUpdates: [
                "media_title": .string("..."),
                "media_position": .double(0),
            ])
        }
    }

    /// Skip to previous track.
    func mediaPrevious(_ entityId: String) async {
        await performAction(domain: "media_player", service: "media_previous_track", data: ["entity_id": entityId]) { [self] in
            haClient.updateEntityOptimistically(entityId, attributeUpdates: [
                "media_title": .string("..."),
                "media_position": .double(0),
            ])
        }
    }

    /// Set volume level (0.0-1.0). Does NOT re-fetch state to prevent slider fighting.
    func setVolume(_ entityId: String, level: Double) async {
        haClient.updateEntityOptimistically(entityId, attributeUpdates: [
            "volume_level": .double(level)
        ])
        do {
            try await haClient.callService(domain: "media_player", service: "volume_set", data: [
                "entity_id": entityId,
                "volume_level": level,
            ])
        } catch {
            // Non-fatal
        }
    }

    /// Toggle mute on a media player.
    func toggleMute(_ entityId: String) async {
        let currentMuted = haClient.entity(entityId)?.isVolumeMuted ?? false
        await performAction(domain: "media_player", service: "volume_mute", data: [
            "entity_id": entityId,
            "is_volume_muted": !currentMuted,
        ]) { [self] in
            haClient.updateEntityOptimistically(entityId, attributeUpdates: [
                "is_volume_muted": .bool(!currentMuted)
            ])
        }
    }

    /// Set shuffle mode.
    func setShuffle(_ entityId: String, enabled: Bool) async {
        await performAction(domain: "media_player", service: "shuffle_set", data: [
            "entity_id": entityId,
            "shuffle": enabled,
        ]) { [self] in
            haClient.updateEntityOptimistically(entityId, attributeUpdates: [
                "shuffle": .bool(enabled)
            ])
        }
    }

    /// Set repeat mode (off -> all -> one cycle).
    func setRepeat(_ entityId: String, mode: String) async {
        await performAction(domain: "media_player", service: "repeat_set", data: [
            "entity_id": entityId,
            "repeat": mode,
        ]) { [self] in
            haClient.updateEntityOptimistically(entityId, attributeUpdates: [
                "repeat": .string(mode)
            ])
        }
    }

    /// Play media on a Sonos speaker entity.
    /// If the speaker is on TV input, switches source first so play_media works.
    /// Shows a toast while waiting for playback to start.
    func playMedia(entityId: String, contentId: String, contentType: String) async {
        // If speaker is on TV input, switch away first
        if let entity = haClient.entity(entityId),
           entity.source?.uppercased() == "TV" {
            do {
                try await haClient.callService(
                    domain: "media_player",
                    service: "select_source",
                    data: [
                        "entity_id": entityId,
                        "source": "Spotify",
                    ]
                )
            } catch is CancellationError {
                return
            } catch {
                // Preserve the existing fallback: play_media may still work on
                // integrations that report a stale source value.
                Self.logger.error(
                    "Speaker source switch failed; continuing with play request."
                )
            }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
        }

        // Show toast with speaker name
        let speakerName = haClient.entity(entityId)?.friendlyName ?? "speaker"
        toastMessage = "Playing on \(speakerName)..."
        toastIsWarning = false

        let mediaContentType: String
        if contentId.hasPrefix("spotify:playlist:") {
            mediaContentType = "playlist"
        } else if contentId.hasPrefix("http") {
            mediaContentType = contentType
        } else {
            mediaContentType = "music"
        }
        do {
            try await haClient.callService(domain: "media_player", service: "play_media", data: [
                "entity_id": entityId,
                "media_content_id": contentId,
                "media_content_type": mediaContentType,
            ])
        } catch {
            toastMessage = nil
            return
        }

        // Monitor for playback: poll every 1s for up to 15s
        for _ in 0..<15 {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                toastMessage = nil
                return
            }
            do {
                _ = try await haClient.fetchSingleEntityState(entityId)
            } catch is CancellationError {
                toastMessage = nil
                return
            } catch {
                // Polling is observational; a later iteration can still confirm
                // playback without changing the command's outcome.
                Self.logger.info(
                    "Speaker playback-state poll failed; the bounded poll will retry."
                )
            }
            if haClient.entity(entityId)?.state == "playing" {
                toastMessage = nil
                return
            }
        }

        // Timeout -- show warning toast for 5s
        toastMessage = "Check speaker -- playback may not have started"
        toastIsWarning = true
        do {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        } catch {
            toastMessage = nil
            return
        }
        if toastIsWarning { toastMessage = nil }
    }

    /// Add media to the Sonos queue without interrupting current playback.
    func enqueueMedia(entityId: String, contentId: String, contentType: String) async {
        let speakerName = haClient.entity(entityId)?.friendlyName ?? "speaker"
        toastMessage = "Added to queue on \(speakerName)"
        toastIsWarning = false

        do {
            try await haClient.callService(domain: "media_player", service: "play_media", data: [
                "entity_id": entityId,
                "media_content_id": contentId,
                "media_content_type": contentType,
                "extra": ["enqueue": "add"],
            ])
        } catch {
            toastMessage = "Failed to add to queue"
            toastIsWarning = true
        }

        do {
            try await Task.sleep(nanoseconds: 3_000_000_000)
        } catch {
            toastMessage = nil
            return
        }
        toastMessage = nil
    }
}
