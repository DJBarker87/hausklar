import AVFoundation
import Speech
import os

@MainActor
final class DictationService: NSObject, ObservableObject {
    private static let logger=Logger(
        subsystem:"org.example.hausklar",category:"DictationService"
    )
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?

    private var recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInputTap = false

    func start(localeIdentifier: String = "en_GB") async {
        errorMessage = nil
        transcript = ""
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))

        guard await requestSpeechPermission() else {
            errorMessage = "Speech recognition permission is required for dictation."
            return
        }
        guard await requestMicrophonePermission() else {
            errorMessage = "Microphone permission is required for dictation."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Dictation is not currently available."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            errorMessage = "On-device dictation is not available for this language."
            return
        }

        stop()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
            hasInputTap = true
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if let error {
                        self.errorMessage = error.localizedDescription
                        self.stop()
                    } else if result?.isFinal == true {
                        self.stop()
                    }
                }
            }
        } catch {
            errorMessage = "Could not start dictation."
            stop()
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,options:.notifyOthersOnDeactivation
            )
        } catch {
            Self.logger.error(
                "Dictation audio-session cleanup failed: \(error.localizedDescription, privacy:.private)"
            )
        }
    }

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
