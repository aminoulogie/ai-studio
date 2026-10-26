import Foundation
import AVFoundation

/// The phone's side of Cursor call: a WebSocket to the AI Studio Companion on a PC on the same Wi-Fi.
/// The page is served from https://aistudio.app, which may not open plain ws:// links itself, so the app does it.
final class StudioPCLink: NSObject, URLSessionWebSocketDelegate {
    /// {event: "open" | "message" | "closed", data?, reason?}
    var onEvent: (([String: Any]) -> Void)?
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)

    /// Only private-network addresses: the companion is never reached over the internet.
    static func isLocal(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, host.split(separator: ".").count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
                || (parts[0] == 169 && parts[1] == 254)
        }
        return host.range(of: "^[A-Za-z0-9-]+(\\.local)?$", options: .regularExpression) != nil
    }

    func connect(host: String, port: Int) throws {
        guard Self.isLocal(host), (1024...65535).contains(port), let url = URL(string: "ws://\(host):\(port)/") else {
            throw NSError(domain: "StudioPCLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "Only a PC on your own Wi-Fi can be paired."])
        }
        close()
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        task.resume()
        receive(task)
    }

    func send(_ text: String) throws {
        guard let task = task else {
            throw NSError(domain: "StudioPCLink", code: 2, userInfo: [NSLocalizedDescriptionKey: "Your PC is not connected."])
        }
        task.send(.string(text)) { [weak self] error in
            if let error = error { DispatchQueue.main.async { self?.lost(task, error.localizedDescription) } }
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.task === task else { return }
                switch result {
                case .success(.string(let text)):
                    self.onEvent?(["event": "message", "data": text]); self.receive(task)
                case .success(.data(let data)):
                    self.onEvent?(["event": "message", "data": String(decoding: data, as: UTF8.self)]); self.receive(task)
                case .success:
                    self.receive(task)
                case .failure(let error):
                    self.lost(task, error.localizedDescription)
                }
            }
        }
    }

    private func lost(_ task: URLSessionWebSocketTask, _ reason: String) {
        guard self.task === task else { return }
        self.task = nil
        onEvent?(["event": "closed", "reason": reason])
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        onEvent?(["event": "open"])
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        lost(webSocketTask, text.isEmpty ? "The PC closed the link." : text)
    }
}

/// Speaks Claude's answers during a call, through the speaker, then tells the page so it can listen again.
final class StudioSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var onDone: ((Bool) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, language: String?, rate: Float?) {
        synth.stopSpeaking(at: .immediate)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language ?? AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = min(max(rate ?? AVSpeechUtteranceDefaultSpeechRate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        synth.speak(utterance)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onDone?(true) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { onDone?(false) }
}
