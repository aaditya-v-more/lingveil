import Foundation
import NaturalLanguage

protocol Translator {
    /// Returns one translation per input, in order. A text already in the target language
    /// may come back unchanged.
    func translate(_ texts: [String], to target: Language) async throws -> [String]
}

/// Picks the engine from settings, falls back to on-device translation when the network
/// engine fails, and caches results so repeated text (live mode, re-opened windows) is instant.
enum Translation {
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func translate(_ texts: [String], to target: Language) async throws -> [String] {
        var results = [String?](repeating: nil, count: texts.count)
        var missing: [String] = []
        lock.withLock {
            for (i, t) in texts.enumerated() {
                if let hit = cache[target.code + "\u{1}" + t] { results[i] = hit } else if !missing.contains(t) { missing.append(t) }
            }
        }
        if !missing.isEmpty {
            let fresh = try await run(missing, to: target)
            lock.withLock {
                if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
                for (s, t) in zip(missing, fresh) { cache[target.code + "\u{1}" + s] = t }
                for i in texts.indices where results[i] == nil { results[i] = cache[target.code + "\u{1}" + texts[i]] }
            }
        }
        return results.enumerated().map { $1 ?? texts[$0] }
    }

    static func cached(_ text: String, to target: Language) -> String? {
        lock.withLock { cache[target.code + "\u{1}" + text] }
    }

    private static func run(_ texts: [String], to target: Language) async throws -> [String] {
        switch Prefs.engine {
        case .auto:
            do { return try await GoogleWeb().translate(texts, to: target) }
            catch { return try await AppleOnDevice().translate(texts, to: target) }
        case .google: return try await GoogleWeb().translate(texts, to: target)
        case .apple: return try await AppleOnDevice().translate(texts, to: target)
        case .googleCloud: return try await GoogleCloud(key: Prefs.googleCloudKey).translate(texts, to: target)
        case .deepl: return try await DeepL(key: Prefs.deeplKey).translate(texts, to: target)
        case .ollama: return try await Ollama(base: Prefs.ollamaURL, model: Prefs.ollamaModel).translate(texts, to: target)
        }
    }

    /// Splits work into request-sized chunks and runs them concurrently, keeping order.
    static func chunked(_ texts: [String], maxItems: Int, maxChars: Int,
                        _ body: @escaping @Sendable ([String]) async throws -> [String]) async throws -> [String] {
        var chunks: [[String]] = [[]]
        var chars = 0
        for t in texts {
            if chunks[chunks.count - 1].count >= maxItems || (chars + t.count > maxChars && !chunks[chunks.count - 1].isEmpty) {
                chunks.append([]); chars = 0
            }
            chunks[chunks.count - 1].append(t); chars += t.count
        }
        return try await withThrowingTaskGroup(of: (Int, [String]).self) { g in
            for (i, c) in chunks.enumerated() { g.addTask { (i, try await body(c)) } }
            var parts = [[String]](repeating: [], count: chunks.count)
            for try await (i, r) in g { parts[i] = r }
            return parts.flatMap { $0 }
        }
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()
}

// MARK: - Google (free, no key)

/// The endpoint Chrome's translate extension uses: batched, per-item language detection,
/// no account or key.
struct GoogleWeb: Translator {
    func translate(_ texts: [String], to target: Language) async throws -> [String] {
        try await Translation.chunked(texts, maxItems: 120, maxChars: 4500) { chunk in
            var c = URLComponents(string: "https://clients5.google.com/translate_a/t")!
            c.queryItems = [.init(name: "client", value: "dict-chrome-ex"), .init(name: "sl", value: "auto"), .init(name: "tl", value: target.code)]
            var req = URLRequest(url: c.url!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = chunk.map { "q=" + Self.formEncode($0) }.joined(separator: "&").data(using: .utf8)
            let (data, resp) = try await Translation.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: data) else {
                throw LingveilError.message("Google Translate is not reachable right now")
            }
            let rows: [Any] = (json as? [Any]) ?? []
            let out: [String] = rows.map { row in
                if let a = row as? [Any], let s = a.first as? String { return s }
                return row as? String ?? ""
            }
            // A single string comes back flattened as [translation, lang].
            if chunk.count == 1, let first = out.first { return [first] }
            guard out.count == chunk.count else { throw LingveilError.message("Unexpected reply from Google Translate") }
            return out
        }
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - Google Cloud (user's key; 500k chars/month free)

struct GoogleCloud: Translator {
    let key: String
    func translate(_ texts: [String], to target: Language) async throws -> [String] {
        guard !key.isEmpty else { throw LingveilError.message("Add a Google Cloud API key in Settings → Engines") }
        return try await Translation.chunked(texts, maxItems: 128, maxChars: 25_000) { chunk in
            var req = URLRequest(url: URL(string: "https://translation.googleapis.com/language/translate/v2?key=\(key)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["q": chunk, "target": target.code, "format": "text"])
            let (data, _) = try await Translation.session.data(for: req)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let list = (obj?["data"] as? [String: Any])?["translations"] as? [[String: Any]] else {
                let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? "Google Cloud request failed"
                throw LingveilError.message(msg)
            }
            return list.map { $0["translatedText"] as? String ?? "" }
        }
    }
}

// MARK: - DeepL (user's key; free tier available)

struct DeepL: Translator {
    let key: String
    func translate(_ texts: [String], to target: Language) async throws -> [String] {
        guard !key.isEmpty else { throw LingveilError.message("Add a DeepL API key in Settings → Engines") }
        let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        let lang: String = switch target.code {
        case "en": "EN-US"
        case "pt": "PT-BR"
        case "zh-CN": "ZH-HANS"
        case "zh-TW": "ZH-HANT"
        case "iw": "HE"
        default: target.code.uppercased()
        }
        return try await Translation.chunked(texts, maxItems: 50, maxChars: 30_000) { chunk in
            var req = URLRequest(url: URL(string: "https://\(host)/v2/translate")!)
            req.httpMethod = "POST"
            req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["text": chunk, "target_lang": lang])
            let (data, resp) = try await Translation.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let list = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["translations"] as? [[String: Any]] else {
                throw LingveilError.message("DeepL request failed (check the key)")
            }
            return list.map { $0["text"] as? String ?? "" }
        }
    }
}

// MARK: - Ollama (local model)

struct Ollama: Translator {
    let base: String
    let model: String
    func translate(_ texts: [String], to target: Language) async throws -> [String] {
        try await Translation.chunked(texts, maxItems: 40, maxChars: 3000) { chunk in
            let prompt = """
            Translate every string in this JSON array into \(target.name). Keep names, numbers, URLs and emoji as they are. \
            Translate UI labels the way a native app in \(target.name) would label them. \
            Reply with only a JSON object {"t": [...]} holding exactly \(chunk.count) strings in the same order.
            \(String(data: try JSONSerialization.data(withJSONObject: chunk), encoding: .utf8)!)
            """
            var req = URLRequest(url: URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/chat")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "stream": false, "format": "json", "think": false,
                "options": ["temperature": 0],
                "messages": [["role": "user", "content": prompt]],
            ] as [String: Any])
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = (obj["message"] as? [String: Any])?["content"] as? String,
                  let inner = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
                  let list = inner["t"] as? [String], list.count == chunk.count else {
                throw LingveilError.message("Ollama did not return a usable translation (is \(model) pulled?)")
            }
            return list
        }
    }
}

// MARK: - Language detection

enum Detect {
    /// True when `text` is confidently already in `lang`, so it can be left untouched.
    static func isAlready(_ text: String, in lang: Language) -> Bool {
        guard text.count >= 4 else { return false }
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let (best, p) = r.languageHypotheses(withMaximum: 1).first else { return false }
        let id = best.rawValue
        return p > 0.85 && (id == lang.appleID || id.hasPrefix(lang.appleID + "-") || lang.appleID.hasPrefix(id))
    }

    static func dominant(_ texts: [String], excluding target: Language) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(texts.prefix(200).joined(separator: "\n"))
        return r.languageHypotheses(withMaximum: 3)
            .filter { $0.key.rawValue != target.appleID }
            .max { $0.value < $1.value }?.key.rawValue
    }
}
