// The Live-call routes exactly as the harness speaks them
// (server/routes/live.ts): the offer posted byte for byte with a longer
// timeout, the two 409 bodies kept whole instead of flattened to "busy", an
// end that reads 404 as "already over", and a settings patch that sends
// only what changed.
import XCTest
@testable import CompanionCore

private final class LiveCallStub: URLProtocol {
    static var capturedRequest: URLRequest?
    static var capturedBody: Data?
    static var statusCode = 200
    static var responseBody = Data("{}".utf8)

    static func reset() {
        capturedRequest = nil
        capturedBody = nil
        statusCode = 200
        responseBody = Data("{}".utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        Self.capturedBody = Self.readBody(from: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class LiveCallClientTests: XCTestCase {
    private var session: URLSession!
    private var client: CompanionClient!

    private static let call = #"{"callId":"c1","botId":"b1","threadId":"t1","client":"ios","voice":"marin","startedAt":1700000000000,"status":"connecting"}"#

    override func setUp() {
        super.setUp()
        LiveCallStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveCallStub.self]
        session = URLSession(configuration: configuration)
        client = CompanionClient(
            connection: Connection(name: "Mac", host: "127.0.0.1", port: 8810),
            token: "paired-token",
            session: session
        )
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        client = nil
        super.tearDown()
    }

    private static func body() throws -> [String: Any] {
        let data = try XCTUnwrap(LiveCallStub.capturedBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - POST /api/live/session

    // App-target lifecycle code cannot be linked by the portable Swift suite.
    // Pin the source binding across the controller's suspending SDP apply.
    func testNativeAbandonedStartKeepsTheClientThatReturnedTheAnswer() throws {
        let iosDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: iosDirectory.appendingPathComponent("App/Session.swift"), encoding: .utf8)
        let controller = try String(contentsOf: iosDirectory.appendingPathComponent("App/LiveCallController.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("return (answer, { self.endLiveCall(callId: answer.call.callId, using: client) })"))
        XCTAssertTrue(controller.contains("created = (start.call.callId, end)"))
        XCTAssertTrue(controller.contains("_ = await created.end().value"))
        XCTAssertFalse(controller.contains("_ = await session.endLiveCall(callId: created.callId).value"))
    }

    func testStartPostsTheOfferAsThisPhoneAndWaitsLongerThanUsual() async throws {
        LiveCallStub.statusCode = 201
        LiveCallStub.responseBody = Data(#"{"call":\#(Self.call),"transport":{"type":"webrtc","sdp":"v=0\r\nanswer"}}"#.utf8)

        let start = try await client.startLiveCall(botId: "b1", threadId: "t1", sdp: "v=0\r\na=offer\r\n")
        XCTAssertEqual(start.call.callId, "c1")
        XCTAssertEqual(start.call.status, .connecting)
        XCTAssertEqual(start.transport.type, "webrtc")
        XCTAssertEqual(start.transport.sdp, "v=0\r\nanswer")

        let request = try XCTUnwrap(LiveCallStub.capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/live/session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer paired-token")
        // The Mac talks to OpenAI (up to 20 s) before it answers and the
        // sidecar allows 30 s until headers; the usual 20 s would cut it off.
        XCTAssertEqual(request.timeoutInterval, 35)
        let body = try Self.body()
        XCTAssertEqual(body["botId"] as? String, "b1")
        XCTAssertEqual(body["threadId"] as? String, "t1")
        XCTAssertEqual(body["client"] as? String, "ios")
        XCTAssertEqual(body["sdp"] as? String, "v=0\r\na=offer\r\n", "the SDP travels byte for byte, CRLF included")
    }

    func testStartOmitsTheThreadWhenTheBotsCurrentThreadIsMeant() async throws {
        LiveCallStub.statusCode = 201
        LiveCallStub.responseBody = Data(#"{"call":\#(Self.call),"transport":{"type":"webrtc","sdp":"v=0"}}"#.utf8)
        _ = try await client.startLiveCall(botId: "b1", threadId: nil, sdp: "v=0")
        XCTAssertEqual(try Self.body().keys.sorted(), ["botId", "client", "sdp"])
    }

    func testStartRefusesAnIdThatCannotBeARoute() async {
        do {
            _ = try await client.startLiveCall(botId: "../x", threadId: nil, sdp: "v=0")
            XCTFail("expected badURL")
        } catch {
            guard case .badURL? = error as? APIError else { return XCTFail("expected badURL, got \(error)") }
        }
        XCTAssertNil(LiveCallStub.capturedRequest, "nothing was sent")
    }

    func testStartWithoutAKeyOnTheMacIsItsOwnError() async {
        LiveCallStub.statusCode = 409
        LiveCallStub.responseBody = Data(#"{"error":"Add an OpenAI API key to use Live calls.","needsKey":true}"#.utf8)
        do {
            _ = try await client.startLiveCall(botId: "b1", threadId: "t1", sdp: "v=0")
            XCTFail("expected needsKey")
        } catch let LiveCallStartError.needsKey(message) {
            XCTAssertEqual(message, "Add an OpenAI API key to use Live calls.")
        } catch {
            XCTFail("expected needsKey, got \(error)")
        }
    }

    func testStartWhileSomeoneIsOnTheLineSaysWho() async {
        LiveCallStub.statusCode = 409
        LiveCallStub.responseBody = Data(#"{"error":"A Live call is already running.","activeCall":{"callId":"c0","botId":"b2","threadId":"t2","client":"desktop","voice":"marin","startedAt":1,"status":"live"}}"#.utf8)
        do {
            _ = try await client.startLiveCall(botId: "b1", threadId: "t1", sdp: "v=0")
            XCTFail("expected busy")
        } catch let LiveCallStartError.busy(active, message) {
            XCTAssertEqual(active.callId, "c0")
            XCTAssertEqual(active.client, "desktop")
            XCTAssertEqual(active.botId, "b2")
            XCTAssertEqual(message, "A Live call is already running.")
        } catch {
            XCTFail("expected busy, got \(error)")
        }
    }

    func testAPlain409IsStillTheGenericError() async {
        LiveCallStub.statusCode = 409
        LiveCallStub.responseBody = Data(#"{"error":"Not now."}"#.utf8)
        do {
            _ = try await client.startLiveCall(botId: "b1", threadId: "t1", sdp: "v=0")
            XCTFail("expected APIError")
        } catch let APIError.status(code, message) {
            XCTAssertEqual(code, 409)
            XCTAssertEqual(message, "Not now.")
        } catch {
            XCTFail("expected APIError.status, got \(error)")
        }
    }

    func testOpenAIRefusalsKeepTheMacsWords() async {
        LiveCallStub.statusCode = 502
        LiveCallStub.responseBody = Data(#"{"error":"OpenAI refused the call (HTTP 401). Check the key on your computer."}"#.utf8)
        do {
            _ = try await client.startLiveCall(botId: "b1", threadId: "t1", sdp: "v=0")
            XCTFail("expected APIError")
        } catch let APIError.status(code, message) {
            XCTAssertEqual(code, 502)
            XCTAssertEqual(message, "OpenAI refused the call (HTTP 401). Check the key on your computer.")
        } catch {
            XCTFail("expected APIError.status, got \(error)")
        }
    }

    // MARK: - POST /api/live/call/end

    func testEndPostsTheCallIdAndReadsTheFinalState() async throws {
        LiveCallStub.statusCode = 200
        LiveCallStub.responseBody = Data(#"{"call":{"callId":"c1","botId":"b1","threadId":"t1","client":"ios","voice":"marin","startedAt":1,"status":"ended","endReason":"hung-up"}}"#.utf8)
        let call = try await client.endLiveCall(callId: "c1")
        XCTAssertEqual(call?.status, .ended)
        XCTAssertEqual(call?.endReason, "hung-up")
        let request = try XCTUnwrap(LiveCallStub.capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/live/call/end")
        XCTAssertEqual(try Self.body()["callId"] as? String, "c1")
    }

    func testEndingACallThatIsAlreadyOverIsNotAnError() async throws {
        LiveCallStub.statusCode = 404
        LiveCallStub.responseBody = Data(#"{"error":"That call is not running."}"#.utf8)
        let call = try await client.endLiveCall(callId: "gone")
        XCTAssertNil(call)
    }

    func testEndStillReportsOtherFailures() async {
        LiveCallStub.statusCode = 503
        LiveCallStub.responseBody = Data(#"{"error":"The desktop connection is starting."}"#.utf8)
        do {
            _ = try await client.endLiveCall(callId: "c1")
            XCTFail("expected APIError")
        } catch let APIError.status(code, message) {
            XCTAssertEqual(code, 503)
            XCTAssertEqual(message, "The desktop connection is starting.")
        } catch {
            XCTFail("expected APIError.status, got \(error)")
        }
    }

    // MARK: - GET /api/live/call

    func testCurrentCallReadsNullAsNoCall() async throws {
        LiveCallStub.responseBody = Data(#"{"call":null}"#.utf8)
        let none = try await client.liveCall()
        XCTAssertNil(none)
        let request = try XCTUnwrap(LiveCallStub.capturedRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/live/call")

        LiveCallStub.responseBody = Data(#"{"call":\#(Self.call)}"#.utf8)
        let running = try await client.liveCall()
        XCTAssertEqual(running?.callId, "c1")
    }

    // MARK: - PATCH /api/live/settings

    func testSettingsPatchSendsOnlyWhatChangedAndReadsTheResult() async throws {
        LiveCallStub.responseBody = Data(#"{"live":{"configured":true,"voice":"marin","readTypedReplies":true,"idleMinutes":10}}"#.utf8)
        let live = try await client.updateLiveSettings(LiveSettingsPatch(idleMinutes: 10))
        XCTAssertEqual(live, LiveSettings(configured: true, voice: "marin", readTypedReplies: true, idleMinutes: 10))
        let request = try XCTUnwrap(LiveCallStub.capturedRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/live/settings")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try Self.body()
        XCTAssertEqual(body.keys.sorted(), ["idleMinutes"], "no key field, no untouched field")
        XCTAssertEqual(body["idleMinutes"] as? Int, 10)
    }

    func testSettingsPatchRejectedByTheMacKeepsItsMessage() async {
        LiveCallStub.statusCode = 400
        LiveCallStub.responseBody = Data(#"{"error":"Those Live settings are not valid. The OpenAI key can only be changed on the Mac."}"#.utf8)
        do {
            _ = try await client.updateLiveSettings(LiveSettingsPatch(voice: "nope"))
            XCTFail("expected APIError")
        } catch let APIError.status(code, message) {
            XCTAssertEqual(code, 400)
            XCTAssertEqual(message, "Those Live settings are not valid. The OpenAI key can only be changed on the Mac.")
        } catch {
            XCTFail("expected APIError.status, got \(error)")
        }
    }
}
