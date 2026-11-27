import Foundation
import Security

struct WebDAVConfiguration: Sendable {
    let baseURL: URL
    let username: String

    init(baseURL: URL, username: String) throws {
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !username.contains(":"), !username.contains("\n"), !username.contains("\r") else {
            throw WebDAVError.invalidConfiguration
        }
        self.baseURL = baseURL.absoluteString.hasSuffix("/") ? baseURL : baseURL.appendingPathComponent("")
        self.username = username
    }
}

enum WebDAVError: LocalizedError {
    case invalidConfiguration, missingPassword, invalidName, invalidResponse, listingTooLarge, anonymousAccess, unsafePreconditions, missing, conflict, http(Int), keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: AppLanguage.text("请输入 HTTPS 地址和有效的用户名。", "Enter an HTTPS URL and a valid username.")
        case .missingPassword: AppLanguage.text("请输入 WebDAV 密码。", "Enter a WebDAV password.")
        case .invalidName: AppLanguage.text("同步文件名无效。", "Invalid sync file name.")
        case .invalidResponse: AppLanguage.text("WebDAV 服务器返回了无效响应。", "The WebDAV server returned an invalid response.")
        case .listingTooLarge: AppLanguage.text("WebDAV 目录列表过大，无法安全处理。", "The WebDAV directory listing is too large to process safely.")
        case .anonymousAccess: AppLanguage.text("服务器允许匿名访问，请先启用访问认证。", "The server permits anonymous access. Enable access authentication first.")
        case .unsafePreconditions: AppLanguage.text("服务器不支持安全的条件创建，同步已停止。", "The server does not enforce safe conditional creation. Sync has stopped.")
        case .missing: AppLanguage.text("云端文件不存在。", "The remote file does not exist.")
        case .conflict: AppLanguage.text("云端文件已存在，未覆盖。", "The remote file already exists and was not overwritten.")
        case .http(let status): AppLanguage.text("WebDAV 服务器返回 HTTP \(status)。", "WebDAV server returned HTTP \(status).")
        case .keychain(let status): AppLanguage.text("无法访问钥匙串（\(status)）。", "Could not access Keychain (\(status)).")
        }
    }
}

/// Stores one explicitly configured account. Passwords are never written into preferences or URLs.
enum WebDAVCredentials {
    private static let service = "com.code-wgl.tico.webdav"
    private static let account = "sync-password"
    static func save(_ password: String) throws {
        guard !password.isEmpty else { throw WebDAVError.missingPassword }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw WebDAVError.keychain(addStatus) }
        } else if status != errSecSuccess { throw WebDAVError.keychain(status) }
    }
    static func load() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw WebDAVError.keychain(status) }
        guard let data = value as? Data, let password = String(data: data, encoding: .utf8), !password.isEmpty else { throw WebDAVError.missingPassword }
        return password
    }
    static func remove() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WebDAVError.keychain(status) }
    }
}

/// Every object is immutable. Conditional creation prevents a retry or another device overwriting it.
struct WebDAVClient: Sendable {
    let configuration: WebDAVConfiguration
    private let authorization: String
    private let session: URLSession

    init(configuration: WebDAVConfiguration, password: String, sessionConfiguration: URLSessionConfiguration = .ephemeral) throws {
        guard !password.isEmpty else { throw WebDAVError.missingPassword }
        self.configuration = configuration
        self.authorization = "Basic " + Data("\(configuration.username):\(password)".utf8).base64EncodedString()
        let config = sessionConfiguration
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    private func request(_ url: URL, method: String, authorized: Bool = true) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if authorized { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return request
    }
    private func objectURL(_ name: String) throws -> URL {
        guard !name.isEmpty, name.count <= 200, name != ".", name != "..",
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else { throw WebDAVError.invalidName }
        return configuration.baseURL.appendingPathComponent(name, isDirectory: false)
    }
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        return (data, http)
    }
    private func requireSuccess(_ status: Int) throws {
        guard (200...299).contains(status) else {
            if status == 404 { throw WebDAVError.missing }
            if status == 412 { throw WebDAVError.conflict }
            throw WebDAVError.http(status)
        }
    }
    /// Reject servers whose target directory is anonymously readable. This check precedes syncing.
    func verifyAuthentication() async throws {
        var anonymous = request(configuration.baseURL, method: "PROPFIND", authorized: false)
        anonymous.setValue("0", forHTTPHeaderField: "Depth")
        let (_, response) = try await perform(anonymous)
        if (200...299).contains(response.statusCode) { throw WebDAVError.anonymousAccess }
        guard response.statusCode == 401 || response.statusCode == 403 else { throw WebDAVError.http(response.statusCode) }
        _ = try await list(depth: "0")
        // A private directory does not guarantee private file reads, and some servers ignore
        // If-None-Match. Test both with a random, content-free object before uploading any data.
        let probe = "tico-probe-\(UUID().uuidString).json"
        try await upload(name: probe, data: Data("{}".utf8))
        do {
            let (_, anonymousFile) = try await perform(request(try objectURL(probe), method: "GET", authorized: false))
            if (200...299).contains(anonymousFile.statusCode) { throw WebDAVError.anonymousAccess }
            guard anonymousFile.statusCode == 401 || anonymousFile.statusCode == 403 else { throw WebDAVError.http(anonymousFile.statusCode) }
            do {
                try await upload(name: probe, data: Data("{}".utf8))
                throw WebDAVError.unsafePreconditions
            } catch WebDAVError.conflict { /* expected */ }
            let (_, deleted) = try await perform(request(try objectURL(probe), method: "DELETE"))
            try requireSuccess(deleted.statusCode)
        } catch {
            _ = try? await perform(request(try objectURL(probe), method: "DELETE"))
            throw error
        }
    }
    func list() async throws -> [String] { try await list(depth: "1") }
    private func list(depth: String) async throws -> [String] {
        var req = request(configuration.baseURL, method: "PROPFIND")
        req.setValue(depth, forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
        let (data, response) = try await perform(req)
        guard response.statusCode == 207 else { try requireSuccess(response.statusCode); throw WebDAVError.invalidResponse }
        // Bound XML parsing work and reject DTDs (including internal entity expansion).
        // The operation files themselves are not subject to this directory-listing limit.
        guard data.count <= 32 * 1024 * 1024 else { throw WebDAVError.listingTooLarge }
        guard !data.contains(0), let xml = String(data: data, encoding: .utf8), !xml.contains("<!DOCTYPE") else {
            throw WebDAVError.invalidResponse
        }
        let parser = DAVListParser(baseURL: configuration.baseURL)
        let names = try parser.parse(data)
        return try names.filter { $0.hasPrefix("sync-op-") && $0.hasSuffix(".json") }.map { name in
            _ = try objectURL(name)
            return name
        }
    }
    func download(name: String) async throws -> Data {
        let (data, response) = try await perform(request(try objectURL(name), method: "GET"))
        try requireSuccess(response.statusCode)
        return data
    }
    func upload(name: String, data: Data) async throws {
        var req = request(try objectURL(name), method: "PUT")
        req.setValue("*", forHTTPHeaderField: "If-None-Match")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (_, response) = try await perform(req)
        try requireSuccess(response.statusCode)
    }
}

/// Reject all redirects, including same-origin redirects: no credentials can escape to another host.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class DAVListParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private var names: [String] = []
    private var text = ""
    private var href: String?
    private var statuses: [Int] = []
    private var isCollection = false
    private var failure: Error?
    private var responseCount = 0
    init(baseURL: URL) { self.baseURL = baseURL }

    func parse(_ data: Data) throws -> [String] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse(), failure == nil, responseCount > 0 else { throw failure ?? WebDAVError.invalidResponse }
        return names
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard namespaceURI == "DAV:" else { return }
        text = ""
        if elementName == "response" { href = nil; statuses = []; isCollection = false }
        if elementName == "collection" { isCollection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard namespaceURI == "DAV:" else { return }
        if elementName == "href" { href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "status" {
            let fields = text.split(separator: " ")
            guard fields.count >= 2, let status = Int(fields[1]) else { failure = WebDAVError.invalidResponse; return }
            statuses.append(status)
        }
        guard elementName == "response" else { return }
        responseCount += 1
        guard let href, !statuses.isEmpty, statuses.allSatisfy({ (200...299).contains($0) }),
              let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
              let baseParts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == baseParts.scheme?.lowercased(),
              parts.host?.lowercased() == baseParts.host?.lowercased(), parts.port == baseParts.port,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            failure = WebDAVError.invalidResponse; return
        }
        let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        let path = url.path
        if path == baseURL.path || path + "/" == basePath { return }
        guard path.hasPrefix(basePath), !isCollection else { return }
        let name = String(path.dropFirst(basePath.count))
        guard !name.isEmpty, !name.contains("/") else { failure = WebDAVError.invalidResponse; return }
        names.append(name)
    }
}
