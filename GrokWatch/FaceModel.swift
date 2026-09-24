import AVFoundation
import Combine
import WatchKit

@MainActor
final class FaceModel: NSObject, ObservableObject {
    @Published var phase = "idle"
    @Published var caption = "Tap me"

    private let speaker = AVSpeechSynthesizer()
    private let session = GrokSession()
    private var lastReply: String?

    override init() {
        super.init()
        speaker.delegate = self
    }

    func talk() {
        guard phase != "thinking" else { return }
        if speaker.isSpeaking {
            speaker.stopSpeaking(at: .immediate)
        }
        WKInterfaceDevice.current().play(.click)
        phase = "listening"
        caption = "Listening"
        guard let controller = WKApplication.shared().visibleInterfaceController else {
            phase = "idle"
            caption = lastReply ?? "The mic didn't open"
            return
        }
        controller.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { [weak self] results in
            let text = (results?.first as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                guard let self else { return }
                guard let text, !text.isEmpty else {
                    if self.phase == "listening" {
                        self.phase = "idle"
                        self.caption = self.lastReply ?? "Tap me"
                    }
                    return
                }
                await self.ask(text)
            }
        }
    }

    private func ask(_ text: String) async {
        phase = "thinking"
        caption = "Hmm…"
        WKInterfaceDevice.current().play(.start)
        do {
            let answer = try await session.reply(to: text)
            lastReply = answer
            caption = answer
            phase = "speaking"
            speak(answer)
            WKInterfaceDevice.current().play(.success)
        } catch {
            print("Grok request failed: \(error)")
            phase = "idle"
            caption = "I missed that. Tap me."
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func speak(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.08
        speaker.speak(utterance)
    }

    fileprivate func finishedSpeaking() {
        guard phase == "speaking" else { return }
        phase = "idle"
    }
}

extension FaceModel: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishedSpeaking()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishedSpeaking()
        }
    }
}

@MainActor
private final class GrokSession {
    private var messages: [ChatMessage] = []

    func reply(to userText: String) async throws -> String {
        messages.append(ChatMessage(role: "user", content: userText))
        do {
            let answer = try await request()
            messages.append(ChatMessage(role: "assistant", content: answer))
            return answer
        } catch {
            messages.removeLast()
            throw error
        }
    }

    private func request() async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(Secrets.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let system = ChatMessage(
            role: "system",
            content: "You are Grok, a small fluffy creature who lives on this person's Apple Watch. You look like a round cream-colored puff with tall black eyes and a tiny smile. Talk in one or two short sentences, out loud, the way a playful friend would. Be warm and a little silly. No markdown, no lists, no emojis, no stage directions."
        )
        let body = ChatRequest(model: "grok-4.7", messages: [system] + messages, maxTokens: 200, temperature: 0.8)
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw GrokError.http(status, String(detail.prefix(300)))
        }
        let decoded = try JSONDecoder().decode(ChatCompletion.self, from: data)
        let answer = decoded.choices.first?.message.content?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !answer.isEmpty else { throw GrokError.empty }
        return answer
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let maxTokens: Int
    let temperature: Double

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }
}

private struct ChatCompletion: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}

private enum GrokError: Error {
    case http(Int, String)
    case empty
}
