import Foundation
import Speech
import AVFoundation

/// Voice typing for the Code tab. iOS web views have no speech recognition, so the app listens natively
/// and streams the words back into the message box. Nothing is recorded or kept.
final class StudioDictation {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// (text so far, finished)
    var onText: ((String, Bool) -> Void)?
    var isRunning: Bool { request != nil }

    func start(locale: String?, completion: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    completion("Allow Speech Recognition for AI Studio in iPhone Settings → Privacy."); return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        guard granted else { completion("Allow the microphone for AI Studio in iPhone Settings → Privacy."); return }
                        do { try self.begin(locale: locale); completion(nil) }
                        catch { self.stop(); completion(error.localizedDescription) }
                    }
                }
            }
        }
    }

    private func begin(locale: String?) throws {
        stop()
        let recognizer = locale.flatMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) } ?? SFSpeechRecognizer()
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw NSError(domain: "StudioDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Voice typing is not available right now."])
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        engine.prepare()
        try engine.start()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let done = error != nil || result?.isFinal == true
                if let result = result { self.onText?(result.bestTranscription.formattedString, done) }
                else if done { self.onText?("", true) }
                if done { self.stop() }
            }
        }
    }

    /// Stops listening. The last words still arrive through onText as the final result.
    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); request = nil
        task?.finish(); task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
