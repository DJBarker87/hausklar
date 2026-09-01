import Foundation
import SwiftUI

extension DeviceActionSheet {
    // MARK: - Speaker Content (Full Controls + Search)

    var speakerContent: some View {
        VStack(spacing: 12) {
            // Now playing header: album art + title/artist/album
            nowPlayingHeader

            // Progress bar
            progressBar

            // Transport controls
            transportControls

            // Volume control
            volumeControl

            // Speaker grouping
            speakerGroupingSection

            // TTS intercom
            ttsIntercomSection

            Divider().background(Self.green.opacity(0.2))

            // Tab picker: scrollable buttons
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SpeakerTab.allCases, id: \.self) { tab in
                        Button {
                            speakerTab = tab
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(speakerTab == tab ? .black : .white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(speakerTab == tab ? Self.green : Self.grey.opacity(0.3))
                                )
                        }
                    }
                }
            }

            switch speakerTab {
            case .nowPlaying:
                EmptyView()
            case .queue:
                queueContent
            case .browse:
                browseContent
            case .search:
                searchContent
            case .books:
                booksContent
            }
        }
        .onAppear {
            volumeSlider = entity?.volumeLevel ?? 0.35
            currentPosition = entity?.mediaPosition ?? 0
            loadAlbumArt()
            startProgressTimer()
            // Pre-wake speaker so it's ready by the time user picks a track
            if let state = entity?.state, state == "off" || state == "idle" {
                Task {
                    _ = await callService(
                        domain: "media_player", service: "turn_on",
                        data: ["entity_id": device.entityId]
                    )
                }
            }
        }
        .onDisappear {
            progressTimer?.invalidate()
            progressTimer = nil
        }
        .onChange(of: entity?.entityPicture) { _, _ in
            loadAlbumArt()
        }
        .onChange(of: entity?.volumeLevel) { _, newValue in
            if let v = newValue {
                volumeSlider = v
            }
        }
        .onChange(of: entity?.mediaPosition) { _, newValue in
            if let p = newValue {
                currentPosition = p
            }
        }
    }

    private var nowPlayingHeader: some View {
        HStack(spacing: 12) {
            // Album art
            Group {
                if let image = albumArtImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.15))
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundStyle(Self.grey)
                        )
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(entity?.mediaTitle ?? "Not Playing")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let artist = entity?.mediaArtist {
                    let albumText = entity?.mediaAlbum.map { " \u{2014} \($0)" } ?? ""
                    Text("\(artist)\(albumText)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Self.grey)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            let duration = entity?.mediaDuration ?? 0
            let progress = duration > 0 ? min(currentPosition / duration, 1.0) : 0

            ProgressView(value: progress)
                .tint(Self.green)
                .background(Self.grey.opacity(0.3))

            HStack {
                Text(formatTime(currentPosition))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Self.grey)
                Spacer()
                Text(formatTime(duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Self.grey)
            }
        }
    }

    private var transportControls: some View {
        HStack(spacing: 24) {
            // Shuffle
            Button {
                HapticManager.light()
                Task { await viewModel.setShuffle(device.entityId, enabled: !(entity?.shuffleEnabled ?? false)) }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 16))
                    .foregroundStyle(entity?.shuffleEnabled == true ? Self.green : Self.grey)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(entity?.shuffleEnabled == true ? "Shuffle on" : "Shuffle off")
            .accessibilityHint("Toggle shuffle")

            // Previous
            Button {
                HapticManager.light()
                Task { await viewModel.mediaPrevious(device.entityId) }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Previous track")

            // Play/Pause
            Button {
                HapticManager.light()
                Task { await viewModel.mediaPlayPause(device.entityId) }
            } label: {
                Image(systemName: entity?.state == "playing" ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Self.green)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(entity?.state == "playing" ? "Pause" : "Play")

            // Next
            Button {
                HapticManager.light()
                Task { await viewModel.mediaNext(device.entityId) }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Next track")

            // Repeat
            Button {
                HapticManager.light()
                let current = entity?.repeatMode ?? "off"
                let next = current == "off" ? "all" : current == "all" ? "one" : "off"
                Task { await viewModel.setRepeat(device.entityId, mode: next) }
            } label: {
                let mode = entity?.repeatMode ?? "off"
                Image(systemName: mode == "one" ? "repeat.1" : "repeat")
                    .font(.system(size: 16))
                    .foregroundStyle(mode != "off" ? Self.green : Self.grey)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Repeat \(entity?.repeatMode ?? "off")")
            .accessibilityHint("Cycle repeat mode")
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.toggleMute(device.entityId) }
            } label: {
                Image(systemName: entity?.isVolumeMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(entity?.isVolumeMuted == true ? Self.red : Self.grey)
                    .frame(width: 24)
            }
            .accessibilityLabel(entity?.isVolumeMuted == true ? "Unmute" : "Mute")

            Slider(value: $volumeSlider, in: 0...1, step: 0.01) { editing in
                if !editing {
                    HapticManager.selection()
                    Task { await viewModel.setVolume(device.entityId, level: volumeSlider) }
                }
            }
            .tint(Self.green)

            Text("\(Int(volumeSlider * 100))%")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Self.grey)
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - Speaker Grouping

    private var speakerGroupingSection: some View {
        VStack(spacing: 8) {
            Divider().background(Self.green.opacity(0.2))

            Text("SPEAKER GROUP")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Self.grey)
                .tracking(1)

            // Show current group members
            let members = entity?.groupMembers ?? []
            if members.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(members, id: \.self) { memberId in
                        let memberEntity = viewModel.haClient.entities[memberId]
                        let name = memberEntity?.friendlyName ?? memberId
                        let isSelf = memberId == device.entityId
                        HStack(spacing: 6) {
                            Image(systemName: "hifispeaker.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(isSelf ? Self.green : Self.grey)
                            Text(name)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(isSelf ? Self.green : .white)
                            if isSelf {
                                Text("(this)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Self.grey)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Not grouped")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Self.grey)
            }

            // Action buttons
            HStack(spacing: 8) {
                // JOIN button
                Button {
                    showGroupPicker = true
                } label: {
                    Text("JOIN")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Self.green))
                }

                // UNJOIN button
                Button {
                    HapticManager.light()
                    Task {
                        _ = await callService(
                            domain: "media_player",
                            service: "unjoin",
                            data: ["entity_id": device.entityId],
                            failureMessage: "The speaker could not leave its group."
                        )
                        viewModel.haClient.scheduleBackgroundRefresh()
                    }
                } label: {
                    Text("UNJOIN")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Self.grey.opacity(0.3)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Self.grey.opacity(0.5), lineWidth: 1))
                }

                // GROUP ALL button
                Button {
                    HapticManager.light()
                    Task {
                        let allSpeakers = availableSpeakers.map { $0.entityId }
                        guard !allSpeakers.isEmpty else { return }
                        _ = await callService(
                            domain: "media_player",
                            service: "join",
                            data: [
                                "entity_id": device.entityId,
                                "group_members": allSpeakers,
                            ],
                            failureMessage: "The speakers could not be grouped."
                        )
                        viewModel.haClient.scheduleBackgroundRefresh()
                    }
                } label: {
                    Text("GROUP ALL")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Self.cyan.opacity(0.3)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Self.cyan.opacity(0.5), lineWidth: 1))
                }
            }

            // Group picker sheet
            if showGroupPicker {
                VStack(spacing: 4) {
                    Text("Select speaker to join:")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.grey)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(availableSpeakers, id: \.entityId) { speaker in
                        Button {
                            HapticManager.light()
                            Task {
                                _ = await callService(
                                    domain: "media_player",
                                    service: "join",
                                    data: [
                                        "entity_id": device.entityId,
                                        "group_members": [speaker.entityId],
                                    ],
                                    failureMessage: "The speaker could not join that group."
                                )
                                viewModel.haClient.scheduleBackgroundRefresh()
                            }
                            showGroupPicker = false
                        } label: {
                            HStack {
                                Image(systemName: "hifispeaker.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Self.green)
                                Text(speaker.friendlyName)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Self.green)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.12)))
                        }
                    }

                    Button {
                        showGroupPicker = false
                    } label: {
                        Text("CANCEL")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Self.grey)
                    }
                    .padding(.top, 4)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.1)))
            }
        }
    }

    /// All media_player entities that are speakers (not this one, not spotify).
    private var availableSpeakers: [HAEntity] {
        viewModel.haClient.entities.values
            .filter { entity in
                entity.domain == "media_player" && entity.entityId != device.entityId && !entity.entityId.contains("spotify")
            }
            .sorted { $0.friendlyName < $1.friendlyName }
    }

    // MARK: - TTS Intercom

    private var ttsIntercomSection: some View {
        VStack(spacing: 8) {
            Divider().background(Self.green.opacity(0.2))

            Text("INTERCOM")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Self.grey)
                .tracking(1)

            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(Self.grey)
                    TextField("Send announcement...", text: $ttsMessage)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white)
                        .submitLabel(.send)
                        .onSubmit { sendTTS() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.15)))

                Button {
                    sendTTS()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.black)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Self.green))
                }
                .disabled(ttsMessage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func sendTTS() {
        let message = ttsMessage.trimmingCharacters(in: .whitespaces)
        guard !message.isEmpty else { return }
        HapticManager.light()
        Task {
            _ = await callService(
                domain: "tts",
                service: "speak",
                data: [
                    "entity_id": device.entityId,
                    "message": message,
                ],
                failureMessage: "The announcement could not be sent."
            )
        }
        ttsMessage = ""
    }

    // MARK: - Queue Content

    private var queueContent: some View {
        VStack(spacing: 12) {
            if queueLoading {
                ProgressView().tint(Self.green).padding()
            } else if queueItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.title2)
                        .foregroundStyle(Self.grey)
                    Text("No queue available")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Self.grey)
                }
                .padding()
            } else {
                ForEach(Array(queueItems.enumerated()), id: \.element.id) { index, track in
                    Button {
                        HapticManager.light()
                        Task {
                            await viewModel.playMedia(
                                entityId: device.entityId,
                                contentId: track.mediaContentId,
                                contentType: track.mediaContentType
                            )
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Self.grey)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if !track.artist.isEmpty {
                                    Text(track.artist)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Self.grey)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Image(systemName: "play.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(Self.green)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .task {
            await loadQueue()
        }
    }

    private func loadQueue() async {
        queueLoading = true
        defer { queueLoading = false }

        if let result = await viewModel.browseMediaHA(
            entityId: device.entityId,
            contentId: "current_queue",
            contentType: "current_queue"
        ) {
            queueItems = result.children.map { item in
                // Extract artist from title if format is "Title - Artist"
                let parts = item.title.components(separatedBy: " - ")
                let title = parts.first ?? item.title
                let artist = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : ""
                return QueueTrack(
                    title: title,
                    artist: artist,
                    mediaContentId: item.mediaContentId,
                    mediaContentType: item.mediaContentType
                )
            }
        }
    }

    // MARK: - Search Content

    private var searchContent: some View {
        VStack(spacing: 12) {
            // Search field
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Self.grey)
                    TextField("Search Spotify...", text: $searchQuery)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white)
                        .submitLabel(.search)
                        .onSubmit { performSearch() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.15))
                )

                Button {
                    performSearch()
                } label: {
                    Text("GO")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Self.green))
                }
                .disabled(searchQuery.isEmpty || isSearching)
            }

            // Category subtabs
            HStack(spacing: 8) {
                ForEach(SearchCategory.allCases, id: \.self) { cat in
                    Button {
                        searchCategory = cat
                        if !searchQuery.isEmpty {
                            performSearch()
                        }
                    } label: {
                        Text(cat.rawValue)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(searchCategory == cat ? .black : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(searchCategory == cat ? Self.green : Self.grey.opacity(0.3))
                            )
                    }
                }
            }

            // Results
            if isSearching {
                ProgressView()
                    .tint(Self.green)
                    .padding()
            } else if !browseStack.isEmpty {
                // Browse view (drilled into an item)
                browseView
            } else if !searchResults.isEmpty {
                searchResultsList
            }
        }
    }

    private var searchResultsList: some View {
        VStack(spacing: 0) {
            ForEach(searchResults) { item in
                Button {
                    handleItemTap(item)
                } label: {
                    searchResultRow(item)
                }
            }
        }
    }

    private var browseView: some View {
        VStack(spacing: 8) {
            // Back button
            Button {
                browseStack.removeLast()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(browseStack.last?.title ?? "Back")
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Self.green)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let current = browseStack.last {
                ForEach(current.items) { item in
                    Button {
                        handleItemTap(item)
                    } label: {
                        searchResultRow(item)
                    }
                }
            }
        }
    }

    private func searchResultRow(_ item: HomeViewModel.BrowseItem) -> some View {
        HStack(spacing: 10) {
            // Thumbnail
            if let thumbnailPath = item.thumbnailPath {
                HomeMediaThumbnailView(path: thumbnailPath)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(white: 0.15))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 16))
                            .foregroundStyle(Self.grey)
                    )
            }

            Text(item.title)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            // Type indicator
            Text(item.mediaContentType.uppercased())
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Self.grey)

            if item.canExpand {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Self.grey)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Browse Content (HA media_player/browse_media)

    private var browseContent: some View {
        VStack(spacing: 12) {
            // Filter field
            HStack {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(Self.grey)
                TextField("Filter...", text: $browseFilter)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.15)))

            // Breadcrumb
            if !browseStack.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Button {
                            browseStack = []
                        } label: {
                            Text("ROOT")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Self.green)
                        }

                        ForEach(Array(browseStack.enumerated()), id: \.offset) { index, level in
                            Text(">")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Self.grey)
                            Button {
                                browseStack = Array(browseStack.prefix(index + 1))
                            } label: {
                                Text(level.title.uppercased())
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Self.green)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            if browseLoading {
                ProgressView().tint(Self.green).padding()
            } else {
                let items = currentBrowseItems
                let filtered =
                    browseFilter.isEmpty
                    ? items
                    : items.filter {
                        $0.title.localizedCaseInsensitiveContains(browseFilter)
                    }

                if filtered.isEmpty && !items.isEmpty {
                    Text("No matches")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Self.grey)
                        .padding()
                } else {
                    ForEach(filtered) { item in
                        Button {
                            handleBrowseItemTap(item)
                        } label: {
                            searchResultRow(item)
                        }
                    }
                }
            }
        }
        .task {
            await loadBrowseRoot()
        }
    }

    private var currentBrowseItems: [HomeViewModel.BrowseItem] {
        browseStack.last?.items ?? browseRootItems
    }

    private func loadBrowseRoot() async {
        browseLoading = true
        // HA browse_media with no content_id returns root categories
        if let result = await viewModel.browseMediaRoot(entityId: device.entityId) {
            browseRootItems = result.children
        }
        browseLoading = false
    }

    private func handleBrowseItemTap(_ item: HomeViewModel.BrowseItem) {
        HapticManager.light()
        if item.canExpand {
            browseLoading = true
            Task {
                if let result = await viewModel.browseMediaHA(
                    entityId: device.entityId,
                    contentId: item.mediaContentId,
                    contentType: item.mediaContentType
                ) {
                    browseStack.append((title: item.title, items: result.children))
                }
                browseLoading = false
            }
        } else if item.canPlay {
            Task {
                await viewModel.playMedia(
                    entityId: device.entityId,
                    contentId: item.mediaContentId,
                    contentType: item.mediaContentType
                )
            }
        }
    }

    // MARK: - Audiobooks Content

    private var booksContent: some View {
        VStack(spacing: 12) {
            if audiobookShowDetail, let detail = audiobookDetail {
                audiobookDetailView(detail)
            } else {
                audiobookGridView
            }
        }
        .task {
            await loadAudiobooks()
        }
    }

    private var audiobookGridView: some View {
        VStack(spacing: 12) {
            // Filter
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Self.grey)
                TextField("Search books...", text: $audiobookFilter)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.15)))

            if audiobookLoading {
                ProgressView().tint(Self.green).padding()
            } else if let audiobookError {
                ContentUnavailableView(
                    "Audiobooks unavailable",
                    systemImage: "books.vertical",
                    description: Text(audiobookError)
                )
            } else {
                let filtered =
                    audiobookFilter.isEmpty
                    ? audiobookItems
                    : audiobookItems.filter {
                        $0.title.localizedCaseInsensitiveContains(audiobookFilter)
                            || $0.author.localizedCaseInsensitiveContains(audiobookFilter)
                    }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ], spacing: 12
                ) {
                    ForEach(filtered) { item in
                        Button {
                            HapticManager.light()
                            loadBookDetail(item.id)
                        } label: {
                            audiobookCard(item)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
        }
    }

    private func audiobookCard(_ item: AudiobookService.LibraryItem) -> some View {
        VStack(spacing: 4) {
            AudiobookCoverView(itemId: item.id, cornerRadius: 6)
                .frame(height: 120)

            Text(item.title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Text(item.author)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Self.grey)
                .lineLimit(1)
        }
    }

    private func audiobookDetailView(_ detail: AudiobookService.ItemDetail) -> some View {
        VStack(spacing: 16) {
            // Back button
            Button {
                audiobookShowDetail = false
                audiobookDetail = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("BOOKS")
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Self.green)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Cover + metadata
            HStack(spacing: 12) {
                AudiobookCoverView(itemId: detail.id, cornerRadius: 8)
                    .frame(width: 100, height: 100)

                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.title)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(detail.author)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Self.grey)

                    if let narrator = detail.narrator {
                        Text("Read by \(narrator)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Self.grey)
                    }

                    Text(formatBookDuration(detail.duration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.grey)

                    if detail.progressFraction > 0 {
                        ProgressView(value: detail.progressFraction)
                            .tint(detail.isFinished ? Self.green : Self.orange)
                    }
                }
            }

            // Resume / Play button
            Button {
                playBook(detail)
            } label: {
                Text(detail.currentTime > 0 ? "RESUME" : "PLAY")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Self.green))
            }

            if let audiobookError {
                Label(audiobookError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Chapter list
            if !detail.chapters.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("CHAPTERS")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.grey)
                        .tracking(1)
                        .padding(.bottom, 8)

                    ForEach(detail.chapters) { chapter in
                        let isCurrent = detail.currentTime >= chapter.start && detail.currentTime < chapter.end
                        Button {
                            playBookAtChapter(detail, chapter: chapter)
                        } label: {
                            HStack {
                                Text(chapter.title)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(isCurrent ? Self.green : .white)
                                    .lineLimit(1)
                                Spacer()
                                Text(formatTime(chapter.start))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Self.grey)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }

    private func loadAudiobooks() async {
        audiobookLoading = true
        audiobookError = nil
        do {
            let libraries = try await AudiobookService.shared.fetchLibraries()
            if let first = libraries.first {
                audiobookItems = try await AudiobookService.shared.fetchLibraryItems(
                    libraryId: first.id
                )
            } else {
                audiobookItems = []
            }
        } catch {
            audiobookItems = []
            audiobookError = error.localizedDescription
        }
        audiobookLoading = false
    }

    private func loadBookDetail(_ itemId: String) {
        audiobookLoading = true
        Task {
            do {
                audiobookDetail = try await AudiobookService.shared.fetchItemDetail(itemId: itemId)
                audiobookShowDetail = true
                audiobookError = nil
            } catch {
                audiobookError = error.localizedDescription
            }
            audiobookLoading = false
        }
    }

    private func playBook(_ detail: AudiobookService.ItemDetail) {
        Task {
            do {
                let response = try await AudiobookService.shared.play(
                    itemId: detail.id,
                    entityId: device.entityId,
                    startTime: detail.currentTime > 0 ? detail.currentTime : nil
                )
                audiobookError =
                    response.available
                    ? nil
                    : (response.reason ?? "Secure audiobook playback is unavailable.")
            } catch {
                audiobookError = error.localizedDescription
            }
        }
    }

    private func playBookAtChapter(_ detail: AudiobookService.ItemDetail, chapter: AudiobookService.Chapter) {
        Task {
            do {
                let response = try await AudiobookService.shared.play(
                    itemId: detail.id,
                    entityId: device.entityId,
                    startTime: chapter.start
                )
                audiobookError =
                    response.available
                    ? nil
                    : (response.reason ?? "Secure audiobook playback is unavailable.")
            } catch {
                audiobookError = error.localizedDescription
            }
        }
    }

    private func formatBookDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    // MARK: - Speaker Helpers

    private func performSearch() {
        guard !searchQuery.isEmpty else { return }
        browseStack = []
        let cacheKey = "\(searchQuery.lowercased().trimmingCharacters(in: .whitespaces)):\(searchCategory.apiValue)"
        if let cached = SearchResultCache.shared.get(key: cacheKey) {
            searchResults = cached
            return
        }
        isSearching = true
        Task {
            let results = await viewModel.searchSpotify(query: searchQuery, category: searchCategory.apiValue)
            SearchResultCache.shared.set(key: cacheKey, items: results)
            searchResults = results
            isSearching = false
        }
    }

    private func handleItemTap(_ item: HomeViewModel.BrowseItem) {
        HapticManager.light()
        if item.canExpand {
            // Drill into this item
            isSearching = true
            Task {
                if let result = await viewModel.browseMedia(contentId: item.mediaContentId, contentType: item.mediaContentType) {
                    browseStack.append((title: item.title, items: result.children))
                }
                isSearching = false
            }
        } else if item.canPlay {
            pendingPlayItem = item
        }
    }

    private func loadAlbumArt() {
        guard
            let path = SpotifyBrowseViewModel.thumbnailProxyPath(
                from: entity?.entityPicture
            )
        else {
            albumArtImage = nil
            return
        }
        Task {
            albumArtImage = await HomeMediaThumbnailService.shared.image(
                for: path,
                maximumPixelSize: 192
            )
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard entity?.state == "playing" else { return }
                currentPosition += 1
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}
