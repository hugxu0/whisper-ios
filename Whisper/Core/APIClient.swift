import Foundation

enum APIError: LocalizedError {
    case http(status: Int, code: String, message: String?)
    case network(String)
    case decoding(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .http(_, let code, let message): return message ?? code
        case .network(let message): return "网络不太好：\(message)"
        case .decoding: return "数据格式不对，请更新 App"
        case .unauthorized: return "登录已失效，请重新登录"
        }
    }

    var code: String? {
        if case .http(_, let code, _) = self { return code }
        return nil
    }
}

struct UploadMeta {
    var kind: String
    var mime: String
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var name: String?
}

/// 和服务端通信。请求体用字典（JSONSerialization），返回值解码成模型。
/// 服务器入口只有 HTTP/1.1，一个连接同时只能跑一个请求：图片视频的上传下载单独用一组连接，
/// 发消息、拉页面这些小请求不会排在大文件后面干等。
final class APIClient {
    let baseURL: URL
    var token: String?
    var onUnauthorized: (() -> Void)?
    private let session: URLSession
    private let transferSession: URLSession
    private let decoder = JSONDecoder()

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
        let transfer = URLSessionConfiguration.default
        transfer.timeoutIntervalForRequest = 60
        transfer.timeoutIntervalForResource = 1800
        transfer.httpMaximumConnectionsPerHost = 4
        transferSession = URLSession(configuration: transfer)
    }

    static var defaultBaseURL: URL {
        if let override = UserDefaults.standard.string(forKey: "serverURL"), let url = URL(string: override), !override.isEmpty {
            return url
        }
        let value = Bundle.main.object(forInfoDictionaryKey: "WhisperServerURL") as? String ?? "https://hoo66.top"
        return URL(string: value)!
    }

    func url(_ path: String, query: [String: String?] = [:]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { components.queryItems = items.sorted { $0.name < $1.name } }
        return components.url!
    }

    func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    // MARK: - 媒体地址

    func mediaURL(_ id: String, thumb: Bool = false) -> URL {
        url(thumb ? "v1/media/\(id)/thumb" : "v1/media/\(id)")
    }

    /// 播放器不方便加请求头，令牌放在查询参数里
    func playableURL(_ id: String) -> URL {
        url("v1/media/\(id)", query: ["token": token])
    }

    var webSocketURL: URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    // MARK: - 请求

    /// timeout 为空时用会话的默认值（30 秒）
    @discardableResult
    func send(_ method: String, _ path: String, query: [String: String?] = [:], body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        var request = authorizedRequest(url(path, query: query))
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request)
    }

    /// cache 为真时把返回的原始 JSON 存进 ResponseCache，下次打开页面先用它
    func get<T: Decodable>(_ path: String, query: [String: String?] = [:], cache: Bool = false, as type: T.Type = T.self) async throws -> T {
        let data = try await send("GET", path, query: query)
        let value: T = try decode(data)
        if cache { ResponseCache.shared.store(data, for: ResponseCache.key(path, query: query)) }
        return value
    }

    /// 上次缓存的结果（没有或者解不开时为 nil），不走网络
    func cached<T: Decodable>(_ path: String, query: [String: String?] = [:], as type: T.Type = T.self) -> T? {
        ResponseCache.shared.value(type, for: ResponseCache.key(path, query: query))
    }

    func post<T: Decodable>(_ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval? = nil, as type: T.Type = T.self) async throws -> T {
        try decode(try await send("POST", path, body: body ?? [:], timeout: timeout))
    }

    func put<T: Decodable>(_ path: String, _ body: [String: Any], as type: T.Type = T.self) async throws -> T {
        try decode(try await send("PUT", path, body: body))
    }

    func patch<T: Decodable>(_ path: String, _ body: [String: Any], as type: T.Type = T.self) async throws -> T {
        try decode(try await send("PATCH", path, body: body))
    }

    func delete(_ path: String) async throws {
        try await send("DELETE", path)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        try check(result.1, result.0)
        return result.0
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                onUnauthorized?()
                throw APIError.unauthorized
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw APIError.http(status: http.statusCode, code: body?["error"] as? String ?? "http_\(http.statusCode)", message: body?["message"] as? String)
        }
    }

    // MARK: - 上传

    /// multipart 上传：meta 字段在前，文件在后。大文件先写到临时文件再上传，避免占内存。
    func upload(meta: UploadMeta, file: URL, filename: String, thumb: Data? = nil, progress: ((Double) -> Void)? = nil) async throws -> MediaInfo {
        let boundary = "whisper-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: body) }
        let handle = try FileHandle(forWritingTo: body)
        var metaJSON: [String: Any] = ["kind": meta.kind, "mime": meta.mime]
        if let width = meta.width { metaJSON["width"] = width }
        if let height = meta.height { metaJSON["height"] = height }
        if let duration = meta.durationMs { metaJSON["durationMs"] = duration }
        if let name = meta.name { metaJSON["name"] = name }
        let metaData = try JSONSerialization.data(withJSONObject: metaJSON)
        func write(_ string: String) { handle.write(Data(string.utf8)) }
        write("--\(boundary)\r\nContent-Disposition: form-data; name=\"meta\"\r\n\r\n")
        handle.write(metaData)
        write("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(meta.mime)\r\n\r\n")
        let source = try FileHandle(forReadingFrom: file)
        while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty { handle.write(chunk) }
        try source.close()
        write("\r\n")
        if let thumb {
            write("--\(boundary)\r\nContent-Disposition: form-data; name=\"thumb\"; filename=\"thumb.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
            handle.write(thumb)
            write("\r\n")
        }
        write("--\(boundary)--\r\n")
        try handle.close()

        var request = authorizedRequest(url("v1/media"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(progress: progress)
        let result: (Data, URLResponse)
        do {
            result = try await transferSession.upload(for: request, fromFile: body, delegate: delegate)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        try check(result.1, result.0)
        let wrapper: MediaWrapper = try decode(result.0)
        return wrapper.media
    }

    /// 下载到本地文件（语音、文件、保存视频用）
    func download(_ url: URL, to destination: URL) async throws {
        let (temporary, response) = try await transferSession.download(for: authorizedRequest(url))
        try check(response, Data())
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// 媒体文件（图片、缩略图）：走单独的连接
    func data(_ url: URL) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await transferSession.data(for: authorizedRequest(url))
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        try check(result.1, result.0)
        return result.0
    }
}

private struct MediaWrapper: Decodable {
    let media: MediaInfo
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let progress: ((Double) -> Void)?

    init(progress: ((Double) -> Void)?) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let progress, totalBytesExpectedToSend > 0 else { return }
        let value = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async { progress(value) }
    }
}
