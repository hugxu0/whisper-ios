import Foundation

/// 接口返回的原始 JSON 存一份在本地：页面打开时先用上次的内容画出来，再在后台刷新。
/// 内存 + 磁盘（Caches/api），按路径和参数存；退出登录时清空。
final class ResponseCache: @unchecked Sendable {
    static let shared = ResponseCache()

    private let lock = NSLock()
    private var memory: [String: (data: Data, savedAt: Date)] = [:]
    private let directory: URL

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("api", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func key(_ path: String, query: [String: String?] = [:]) -> String {
        let items = query.compactMap { key, value in value.map { "\(key)=\($0)" } }.sorted()
        return items.isEmpty ? path : "\(path)?\(items.joined(separator: "&"))"
    }

    /// 文件名用稳定的哈希（Swift 自带的 hashValue 每次启动都不一样）
    private func fileURL(_ key: String) -> URL {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return directory.appendingPathComponent("\(String(hash, radix: 16)).json")
    }

    func data(for key: String) -> (data: Data, savedAt: Date)? {
        lock.lock()
        if let hit = memory[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let url = fileURL(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let savedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        lock.lock()
        memory[key] = (data, savedAt)
        lock.unlock()
        return (data, savedAt)
    }

    func value<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let entry = data(for: key) else { return nil }
        return try? JSONDecoder().decode(type, from: entry.data)
    }

    /// 上次存下来到现在过了多久；没有缓存时为 nil
    func age(for key: String) -> TimeInterval? {
        data(for: key).map { Date().timeIntervalSince($0.savedAt) }
    }

    func store(_ data: Data, for key: String) {
        lock.lock()
        memory[key] = (data, Date())
        lock.unlock()
        try? data.write(to: fileURL(key), options: .atomic)
    }

    func clear() {
        lock.lock()
        memory = [:]
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
