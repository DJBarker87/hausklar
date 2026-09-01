import SwiftUI

/// SITREP display with hacker-style loading animation and typewriter effect.
struct SitrepView: View {
    let entities: [String: HAEntity]
    @Environment(\.dismiss) private var dismiss

    private static let green = Color.hackerGreen
    private static let grey = Color.hackerGrey

    @State private var phase: Phase = .loading
    @State private var loadingLines: [String] = []
    @State private var displayedText = ""
    @State private var fullReport = ""
    @State private var showCursor = true
    @State private var lastUpdated = Date()
    @State private var animationTask: Task<Void,Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Phase {
        case loading
        case typing
        case done
    }

    private static let loadingMessages = [
        "> INITIALISING LOCAL AI CORE...",
        "> BYPASSING MAINFRAME SECURITY PROTOCOLS",
        "> ROUTING THROUGH ENCRYPTED ZIGBEE MESH",
        "> DECRYPTING SENSOR TELEMETRY [AES-256]",
        "> HACKING INTO KERNEL... ACCESS GRANTED",
        "> DEPLOYING NEURAL NETWORK v7.4.1",
        "> SCANNING ALL FLOORS FOR ANOMALIES",
        "> CROSS-REFERENCING THERMAL SIGNATURES",
        "> INTERROGATING SMART HOME ENDPOINTS",
        "> COMPILING INTELLIGENCE BRIEF...",
        "> SITREP READY — TRANSMITTING...",
    ]

    /// Bright green for the latest hacker line (#39ff6e)
    private static let hackerBright = Color(red: 0x39 / 255.0, green: 0xFF / 255.0, blue: 0x6E / 255.0)
    /// Dim green for previous hacker lines (#1a5c2a)
    private static let hackerDim = Color(red: 0x1A / 255.0, green: 0x5C / 255.0, blue: 0x2A / 255.0)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.gray)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close situation report")
                Spacer()
                Text("SITUATION REPORT")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Self.green)
                    .tracking(2)
                Spacer()
                Button {
                    HapticManager.light()
                    regenerate()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                        .foregroundStyle(Self.green)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .disabled(phase != .done)
                .opacity(phase == .done ? 1 : 0.3)
                .accessibilityLabel("Refresh situation report")
            }
            .padding(.horizontal)
            .padding(.top, 12)

            Divider().background(Self.green.opacity(0.2)).padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if phase == .loading || phase == .typing {
                        // Hacker loading lines with dim/bright effect
                        ForEach(Array(loadingLines.enumerated()), id: \.offset) { index, line in
                            let isLatest = index == loadingLines.count - 1 && phase == .loading
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(isLatest ? Self.hackerBright : Self.hackerDim)
                                .opacity(isLatest ? 0.9 : 0.4)
                                .lineSpacing(4)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: loadingLines.count)
                                .transition(.opacity)
                        }

                        if phase == .loading {
                            // Blinking cursor during loading
                            Text("█")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Self.green)
                                .opacity(showCursor ? 1 : 0)
                                .padding(.top, 4)
                        }
                    }

                    if phase == .typing || phase == .done {
                        // Report text with section coloring
                        reportView
                            .padding(.top, 8)
                    }

                    if phase == .typing {
                        Text("█")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Self.green)
                            .opacity(showCursor ? 1 : 0)
                    }

                    if phase == .done {
                        Text("LAST UPDATED: \(formatTime(lastUpdated))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Self.grey)
                            .padding(.top, 16)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .task {
            await runAnimation()
        }
        .onDisappear {
            animationTask?.cancel()
            animationTask=nil
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            if !reduceMotion {
                showCursor.toggle()
            }
        }
    }

    private var reportView: some View {
        VStack(alignment: .leading, spacing: 2) {
            let lines = displayedText.components(separatedBy: "\n")
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.contains("━") {
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Self.green.opacity(0.3))
                } else if let colonIndex = line.firstIndex(of: ":"),
                          line.distance(from: line.startIndex, to: colonIndex) < 15 {
                    let label = String(line[line.startIndex...colonIndex])
                    let content = String(line[line.index(after: colonIndex)...])
                    HStack(alignment: .top, spacing: 0) {
                        Text(label)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Self.grey)
                        Text(content)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.contains("ALERT") || line.contains("WARNING") ? Color.red : Self.green)
                    }
                } else {
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Self.green)
                }
            }
        }
    }

    private func runAnimation() async {
        phase = .loading
        loadingLines = []

        if reduceMotion {
            // Skip animations entirely when reduce motion is enabled (#42)
            loadingLines = Self.loadingMessages
            fullReport = SitrepGenerator.generate(entities: entities)
            lastUpdated = Date()
            displayedText = fullReport
            phase = .done
            return
        }

        // Stream loading lines at 120-160ms intervals (matching React: 120 + random * 40)
        for msg in Self.loadingMessages {
            let randomDelay = UInt64.random(in: 0...40_000_000)
            guard await pause(nanoseconds:120_000_000 + randomDelay) else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                loadingLines.append(msg)
            }
        }

        // Generate report
        fullReport = SitrepGenerator.generate(entities: entities)
        lastUpdated = Date()

        // Brief pause before typing
        guard await pause(nanoseconds:300_000_000) else { return }
        phase = .typing
        displayedText = ""

        // Typewriter: 2 chars every 8ms
        for char in fullReport {
            displayedText.append(char)
            guard await pause(nanoseconds:8_000_000) else { return }
        }

        phase = .done
    }

    private func regenerate() {
        animationTask?.cancel()
        phase = .loading
        loadingLines = []
        displayedText = ""
        animationTask=Task {
            await runAnimation()
        }
    }

    private func pause(nanoseconds:UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds:nanoseconds)
            return !Task.isCancelled
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
