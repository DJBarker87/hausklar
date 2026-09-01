import AVKit
import Foundation
import SwiftUI
import os

struct DeviceActionSheet: View {
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "DeviceActionSheet"
    )

    let device: FloorPlanDevice
    let viewModel: HomeViewModel

    /// Live entity lookup -- always reads current state from HAClient rather than
    /// capturing a stale snapshot at sheet creation time.
    var entity: HAEntity? { viewModel.haClient.entities[device.entityId] }
    @Environment(\.dismiss) private var dismiss
    // Module-internal only for the same-type camera extension; not public API.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    // Module-internal solely so same-type extensions in DeviceAction*.swift can
    // operate on this exact view instance. These members are not public API.
    // Camera-specific state
    @State var snapshotImage: UIImage?
    @State var cameraTimestamp: String = ""
    @State var snapshotPollingTask: Task<Void, Never>?
    @State var cameraMode: CameraMode = .live
    @State var eventLoading = false
    @State var eventPlaybackUnavailable = false
    @State var zoomScale: CGFloat = 1.0
    @State var lastZoomScale: CGFloat = 1.0
    @State var zoomOffset: CGSize = .zero
    @State var lastZoomOffset: CGSize = .zero
    @State var eventIndex: Int = 0
    @State var videoPlayer: AVPlayer?

    // Speaker-specific state
    @State var speakerTab: SpeakerTab = .nowPlaying
    @State var searchQuery = ""
    @State var searchCategory: SearchCategory = .artist
    @State var searchResults: [HomeViewModel.BrowseItem] = []
    @State var isSearching = false
    @State var browseStack: [(title: String, items: [HomeViewModel.BrowseItem])] = []
    @State var volumeSlider: Double = 0.35
    @State var brightnessSlider: Double = 0
    @State var albumArtImage: UIImage?
    @State var progressTimer: Timer?
    @State var currentPosition: Double = 0

    // Browse-specific state
    @State var browseRootItems: [HomeViewModel.BrowseItem] = []
    @State var browseLoading = false
    @State var browseFilter = ""
    @State var pendingPlayItem: HomeViewModel.BrowseItem?

    // Audiobook-specific state
    @State var audiobookItems: [AudiobookService.LibraryItem] = []
    @State var audiobookDetail: AudiobookService.ItemDetail?
    @State var audiobookShowDetail = false
    @State var audiobookLoading = false
    @State var audiobookFilter = ""
    @State var audiobookError: String?

    // TRV slider state
    @State var trvSliderValue: Double = 20.0
    @State var trvSliderEditing = false

    // Speaker grouping state
    @State var showGroupPicker = false

    // TTS intercom state
    @State var ttsMessage = ""

    // Queue state
    @State var queueItems: [QueueTrack] = []
    @State var queueLoading = false

    // Contact and boiler state
    @State var doorEvent: HAClient.DoorEvent?
    @State var showDoorHistory = false
    @State var showBoilerDetail = false
    @State var showHistoryChart = false

    struct QueueTrack: Identifiable {
        let id = UUID()
        let title: String
        let artist: String
        let mediaContentId: String
        let mediaContentType: String
    }

    enum CameraMode: String, CaseIterable {
        case live = "LIVE"
        case events = "EVENTS"
    }

    enum SpeakerTab: String, CaseIterable {
        case nowPlaying = "NOW PLAYING"
        case queue = "QUEUE"
        case browse = "BROWSE"
        case search = "SEARCH"
        case books = "BOOKS"
    }

    enum SearchCategory: String, CaseIterable {
        case artist = "ARTIST"
        case track = "SONG"
        case playlist = "PLAYLIST"

        var apiValue: String {
            switch self {
            case .artist: return "artist"
            case .track: return "track"
            case .playlist: return "playlist"
            }
        }
    }

    // For camera definitions — match by entityId since device.id may differ from CameraDefinition.id
    var cameraDefinition: FloorPlanData.CameraDefinition? {
        FloorPlanData.cameras.first { $0.entityId == device.entityId }
    }

    static let green = Color.hackerGreen
    static let red = Color.hackerRed
    static let orange = Color.hackerOrange
    static let cyan = Color.hackerCyan
    static let grey = Color.hackerGrey

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 16) {
                // Drag indicator
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)

                // Device header
                HStack(spacing: 12) {
                    deviceIcon
                        .font(.title2)
                        .foregroundStyle(accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.label)
                            .font(.system(.headline, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(device.type.uppercased())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Self.grey)
                    }

                    Spacer()

                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.gray)
                    }
                }
                .padding(.horizontal)

                Divider()
                    .background(Self.green.opacity(0.2))

                // Content by device type
                ScrollView {
                    Group {
                        switch device.type {
                        case "light", "plug":
                            lightPlugContent
                        case "trv":
                            trvContent
                        case "contact":
                            contactContent
                        case "speaker":
                            speakerContent
                        case "appliance":
                            applianceContent
                        case "boiler":
                            boilerContent
                        case "motion":
                            motionContent
                        case "temperature":
                            temperatureContent
                        case "camera":
                            cameraContent
                        default:
                            genericContent
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }

            // Toast overlay
            if let toast = viewModel.toastMessage {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(viewModel.toastIsWarning
                                  ? Self.orange.opacity(0.9)
                                  : Self.green.opacity(0.9))
                    )
                    .padding(.bottom, 24)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: toast)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.08))
        .confirmationDialog("", isPresented: Binding(
            get: { pendingPlayItem != nil },
            set: { if !$0 { pendingPlayItem = nil } }
        )) {
            if let item = pendingPlayItem {
                Button("Play Now") {
                    Task {
                        await viewModel.playMedia(entityId: device.entityId, contentId: item.mediaContentId, contentType: item.mediaContentType)
                    }
                    pendingPlayItem = nil
                }
                Button("Add to Queue") {
                    Task {
                        await viewModel.enqueueMedia(entityId: device.entityId, contentId: item.mediaContentId, contentType: item.mediaContentType)
                    }
                    pendingPlayItem = nil
                }
                Button("Cancel", role: .cancel) { pendingPlayItem = nil }
            }
        } message: {
            if let item = pendingPlayItem {
                Text(item.title)
            }
        }
    }

    // Device-specific content is implemented by same-type extensions in
    // neighboring DeviceAction*.swift files.

    // Module-internal for the same-type device extensions; not public API.
    @MainActor
    @discardableResult
    func callService(
        domain: String,
        service: String,
        data: [String: Any],
        failureMessage: String? = nil
    ) async -> Bool {
        do {
            try await viewModel.haClient.callService(
                domain: domain,
                service: service,
                data: data
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            Self.logger.error(
                "Home Assistant device action failed; the next explicit action can retry it."
            )
            if let failureMessage {
                viewModel.errorMessage = failureMessage.localized
                HapticManager.error()
            }
            return false
        }
    }
}
