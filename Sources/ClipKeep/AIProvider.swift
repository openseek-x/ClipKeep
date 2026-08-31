import Foundation

protocol AIProvider {
    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error>
}

enum AIEndpointPolicy {
    static func validatedBaseURL(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.query == nil else {
            throw AIError.invalidBaseURL
        }
        if scheme == "https" { return url }
        if scheme == "http" && isLoopback(host) { return url }
        throw AIError.insecureEndpoint
    }

    static func isAllowedRedirect(from original: URL, to target: URL) -> Bool {
        guard let validated = try? validatedBaseURL(target.absoluteString) else { return false }
        return original.scheme?.lowercased() == validated.scheme?.lowercased()
            && original.host?.lowercased() == validated.host?.lowercased()
            && original.port == validated.port
    }

    /// Keychain 凭据按 origin 隔离；路径变化不需重复输入，但主机、协议或端口变化必须换 Key。
    static func credentialScope(for value: String) throws -> String {
        let url = try validatedBaseURL(value)
        let scheme = url.scheme!.lowercased()
        let rawHost = url.host!.lowercased()
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

final class SecureSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let originalURL: URL

    init(originalURL: URL) {
        self.originalURL = originalURL
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url,
              AIEndpointPolicy.isAllowedRedirect(from: originalURL, to: target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum AIProviderFactory {
    static func make(settings: AISettings, apiKey: String) throws -> AIProvider {
        let validated = settings.validated()
        let baseURL = try AIEndpointPolicy.validatedBaseURL(validated.baseURL)
        guard !validated.model.isEmpty else { throw AIError.invalidModel }
        switch validated.provider {
        case .openAI:
            guard !apiKey.isEmpty else { throw AIError.missingAPIKey }
            return OpenAIResponsesProvider(baseURL: baseURL, apiKey: apiKey)
        case .localCompatible:
            return LocalCompatibleProvider(baseURL: baseURL, apiKey: apiKey)
        }
    }
}

class StreamingHTTPProvider {
    private static let maxStreamBytes = 512 * 1024
    let baseURL: URL
    let apiKey: String

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    func stream(request: URLRequest,
                parseEvent: @escaping (Data) throws -> StreamParseResult) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = request.timeoutInterval
                    configuration.timeoutIntervalForResource = request.timeoutInterval
                    configuration.httpMaximumConnectionsPerHost = 1
                    let delegate = SecureSessionDelegate(originalURL: request.url!)
                    let session = URLSession(configuration: configuration, delegate: delegate,
                                             delegateQueue: nil)
                    defer { session.invalidateAndCancel() }

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes.prefix(32_768) { body.append(byte) }
                        throw AIError.httpStatus(http.statusCode, Self.errorMessage(from: body))
                    }

                    var emitted = false
                    var receivedBytes = 0
                    var lineData = Data()

                    func processLine(_ rawLine: Data) throws -> Bool {
                        var lineData = rawLine
                        if lineData.last == 0x0D { lineData.removeLast() }
                        guard let line = String(data: lineData, encoding: .utf8),
                              line.hasPrefix("data:") else { return false }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { return true }
                        guard let data = payload.data(using: .utf8) else { return false }
                        switch try parseEvent(data) {
                        case .delta(let delta):
                            if !delta.isEmpty {
                                emitted = true
                                continuation.yield(delta)
                            }
                        case .finished:
                            break
                        }
                        return false
                    }

                    var finished = false
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        receivedBytes += 1
                        guard receivedBytes <= Self.maxStreamBytes else {
                            throw AIError.responseTooLarge
                        }
                        if byte == 0x0A {
                            finished = try processLine(lineData)
                            lineData.removeAll(keepingCapacity: true)
                            if finished { break }
                        } else {
                            lineData.append(byte)
                        }
                    }
                    if !finished && !lineData.isEmpty { _ = try processLine(lineData) }
                    if !emitted { throw AIError.emptyResponse }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func authorizedRequest(url: URL, body: Data, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        return request
    }

    static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return String(message.prefix(1_000))
        }
        return ""
    }
}

enum StreamParseResult {
    case delta(String)
    case finished
}
