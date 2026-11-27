import Foundation
import Testing
@testable import Tic

@Suite("WebDAV transport", .serialized)
struct WebDAVClientTests {
    func client() throws -> WebDAVClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DAVProtocolStub.self]
        return try WebDAVClient(configuration: WebDAVConfiguration(baseURL: URL(string: "https://example.test/dav/")!, username: "alice"), password: "secret", sessionConfiguration: config)
    }

    @Test func refusesAnonymousAccess() async throws {
        DAVProtocolStub.set([(207, Data())])
        await #expect(throws: WebDAVError.self) { try await client().verifyAuthentication() }
        #expect(DAVProtocolStub.requests().count == 1)
        #expect(DAVProtocolStub.requests()[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func refusesPublicObjectsAndCleansUpProbe() async throws {
        let root = "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/dav/</d:href><d:status>HTTP/1.1 200 OK</d:status></d:response></d:multistatus>"
        DAVProtocolStub.set([(401, Data()), (207, Data(root.utf8)), (201, Data()), (200, Data()), (204, Data())])
        await #expect(throws: WebDAVError.self) { try await client().verifyAuthentication() }
        let requests = DAVProtocolStub.requests()
        #expect(requests.map(\.httpMethod) == ["PROPFIND", "PROPFIND", "PUT", "GET", "DELETE"])
        #expect(requests[3].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func authenticationOnlyListsTheDirectoryItself() async throws {
        let root = "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/dav/</d:href><d:status>HTTP/1.1 200 OK</d:status></d:response></d:multistatus>"
        DAVProtocolStub.set([(401, Data()), (207, Data(root.utf8)), (201, Data()), (403, Data()), (412, Data()), (204, Data())])
        try await client().verifyAuthentication()
        let requests = DAVProtocolStub.requests()
        #expect(requests[0].value(forHTTPHeaderField: "Depth") == "0")
        #expect(requests[1].value(forHTTPHeaderField: "Depth") == "0")
    }

    @Test func refusesServerIgnoringPreconditions() async throws {
        let root = "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/dav/</d:href><d:status>HTTP/1.1 200 OK</d:status></d:response></d:multistatus>"
        DAVProtocolStub.set([(401, Data()), (207, Data(root.utf8)), (201, Data()), (403, Data()), (200, Data()), (204, Data())])
        await #expect(throws: WebDAVError.self) { try await client().verifyAuthentication() }
        #expect(DAVProtocolStub.requests().last?.httpMethod == "DELETE")
    }

    @Test func rejectsRedirectWithoutForwarding() async throws {
        DAVProtocolStub.set([(302, Data())])
        await #expect(throws: WebDAVError.self) { try await client().download(name: "sync-op-1.json") }
        #expect(DAVProtocolStub.requests().count == 1)
    }

    @Test func rejectsDocumentTypeDeclarations() async throws {
        let xml = "<!DOCTYPE x [<!ENTITY expansion \"value\">]><d:multistatus xmlns:d=\"DAV:\"/>"
        DAVProtocolStub.set([(207, Data(xml.utf8))])
        await #expect(throws: WebDAVError.self) { _ = try await client().list() }
    }

    @Test func refusesFailedMultistatus() async throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/sync-op-1.json</d:href><d:status>HTTP/1.1 403 Forbidden</d:status></d:response></d:multistatus>
        """
        DAVProtocolStub.set([(207, Data(xml.utf8))])
        await #expect(throws: WebDAVError.self) { try await client().list() }
    }

    @Test func ignoresUnrelatedNamesAndRefusesOverwrite() async throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/my%20file.txt</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/sync-op-1.json</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """
        DAVProtocolStub.set([(207, Data(xml.utf8)), (412, Data())])
        let client = try client()
        #expect(try await client.list() == ["sync-op-1.json"])
        await #expect(throws: WebDAVError.self) { try await client.upload(name: "sync-op-1.json", data: Data()) }
        #expect(DAVProtocolStub.requests().last?.value(forHTTPHeaderField: "If-None-Match") == "*")
    }
}

private final class DAVProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [(Int, Data)] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static func set(_ values: [(Int, Data)]) { lock.lock(); defer { lock.unlock() }; responses = values; recorded = [] }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let response = Self.responses.isEmpty ? (500, Data()) : Self.responses.removeFirst()
        Self.lock.unlock()
        let http = HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/xml"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
