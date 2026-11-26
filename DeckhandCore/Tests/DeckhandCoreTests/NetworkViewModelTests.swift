import Foundation
import Testing
@testable import DeckhandCore

private func flow(_ id: Int, _ method: String = "GET", host: String = "api.example.com", path: String = "/", status: Int? = 200,
                  app: String? = "MyApp", device: String? = "SIM", state: HTTPFlow.State = .complete) -> HTTPFlow {
    var flow = HTTPFlow(id: id, client: ClientInfo(app: app, deviceId: device), scheme: "https", host: host, port: 443, method: method, path: path)
    flow.status = status
    flow.state = state
    return flow
}

@MainActor
private func makeModel() -> NetworkViewModel {
    NetworkViewModel(debounce: .milliseconds(5), makeAuthority: { throw CertificateError.identity("no CA in tests") }) { nil }
}

private let simulator = Device(id: "SIM", name: "iPhone", platform: .ios, osVersion: "iOS", state: .running)

@Test func filterMatchesMethodStatusAppAndText() {
    let get = flow(1, path: "/users?id=7")
    let failed = flow(2, "POST", status: nil, state: .failed)
    #expect(HTTPFilter(query: "USERS").compiled().matches(get))
    #expect(!HTTPFilter(query: "orders").compiled().matches(get))
    #expect(HTTPFilter(methods: ["POST"]).compiled().matches(failed))
    #expect(!HTTPFilter(methods: ["POST"]).compiled().matches(get))
    #expect(HTTPFilter(statusClasses: [2]).compiled().matches(get))
    #expect(HTTPFilter(statusClasses: [0]).compiled().matches(failed))
    #expect(!HTTPFilter(statusClasses: [4, 5]).compiled().matches(get))
    #expect(HTTPFilter(apps: ["MyApp"]).compiled().matches(get))
    #expect(!HTTPFilter(apps: ["Other"]).compiled().matches(get))
    #expect(HTTPFilter(query: #"id=\d+"#, isRegex: true).compiled().matches(get))
    #expect(!HTTPFilter(query: "(", isRegex: true).isValid)
}

@Test func filterCanSearchHeadersAndBodies() {
    var item = flow(1)
    item.requestHeaders = [HTTPHeader("Authorization", "Bearer secrettoken")]
    item.responseBody = Data(#"{"name":"needle"}"#.utf8)
    item.responseHeaders = [HTTPHeader("Content-Type", "application/json")]
    #expect(!HTTPFilter(query: "secrettoken").compiled().matches(item))   // the URL alone does not contain it
    #expect(HTTPFilter(query: "secrettoken", scopes: [.url, .headers]).compiled().matches(item))
    #expect(HTTPFilter(query: "needle", scopes: [.body]).compiled().matches(item))
}

@Test func undecryptedTunnelsAreHiddenUnlessTheyFailed() {
    var tunnel = flow(1, "CONNECT")
    tunnel.isTunnel = true
    #expect(!HTTPFilter().compiled().matches(tunnel))
    #expect(HTTPFilter(hidesTunnels: false).compiled().matches(tunnel))
    tunnel.state = .failed
    #expect(HTTPFilter().compiled().matches(tunnel))
}

@MainActor
@Test func flowsUpdateInPlaceAndAreFilteredLive() async {
    let model = makeModel()
    await model.select(simulator)
    model.receive(flow(1, status: nil, state: .waiting))
    model.receive(flow(2, "POST", app: "Other"))
    model.flushPending()
    #expect(model.visible.map(\.id) == [1, 2])
    #expect(model.apps.map(\.name) == ["MyApp", "Other"])

    model.receive(flow(1, status: 200))   // the response arrives
    model.flushPending()
    #expect(model.visible.count == 2 && model.visible[0].status == 200)

    model.filter = HTTPFilter(apps: ["Other"])
    // the filter is applied after a short debounce; other tests keep the main actor busy meanwhile
    for _ in 0..<100 where model.visible.map(\.id) != [2] { try? await Task.sleep(for: .milliseconds(20)) }
    #expect(model.visible.map(\.id) == [2])
    model.receive(flow(3, app: "Other"))
    model.receive(flow(4, app: "MyApp"))
    model.flushPending()
    #expect(model.visible.map(\.id) == [2, 3])
    #expect(model.totalCount == 4)
}

@MainActor
@Test func aDevicesFlowsAreSeparatedFromOthersAndFiltersFollowTheDevice() async {
    let model = makeModel()
    await model.select(simulator)
    model.receive(flow(1, device: "SIM"))
    model.receive(flow(2, device: "OTHER"))
    model.flushPending()
    #expect(model.visible.map(\.id) == [1])
    model.limitsToDevice = false
    #expect(model.visible.map(\.id) == [1, 2])

    model.filter = HTTPFilter(query: "mine")
    let other = Device(id: "OTHER", name: "iPad", platform: .ios, osVersion: "iOS", state: .running)
    await model.select(other)
    #expect(model.filter == HTTPFilter())
    await model.select(simulator)
    #expect(model.filter.query == "mine")
}

@MainActor
@Test func theBufferKeepsOnlyTheNewestFlows() async {
    let model = NetworkViewModel(capacity: 20, debounce: .milliseconds(5), makeAuthority: { throw CertificateError.identity("x") }) { nil }
    await model.select(simulator)
    for id in 1...30 { model.receive(flow(id)) }
    model.flushPending()
    #expect(model.totalCount <= 20)
    #expect(model.visible.last?.id == 30)
    #expect(model.visible.first?.id != 1)
    #expect(model.visible.count == model.totalCount)
}

@Test func curlCommandRepeatsTheRequest() {
    var item = HTTPFlow(id: 1, scheme: "https", host: "api.example.com", port: 443, method: "POST", path: "/v1/items?x=1")
    item.requestHeaders = [HTTPHeader("Content-Type", "application/json"), HTTPHeader("Host", "api.example.com"),
                           HTTPHeader("Content-Length", "13"), HTTPHeader("Accept-Encoding", "gzip"), HTTPHeader("X-Note", "it's")]
    item.requestBody = Data(#"{"a":"it's"}"#.utf8)
    let command = FlowFormatter.curl(for: item)
    #expect(command == #"curl -X POST 'https://api.example.com/v1/items?x=1' -H 'Content-Type: application/json' -H 'X-Note: it'\''s' --compressed --data-raw '{"a":"it'\''s"}'"#)
}

@Test func bodiesAreClassifiedAndPrettyPrinted() {
    #expect(FlowFormatter.kind(of: Data(#"{"a":1}"#.utf8), mimeType: nil) == .json)
    #expect(FlowFormatter.kind(of: Data([0x89, 0x50, 0x4e, 0x47, 0, 0]), mimeType: nil) == .image)
    #expect(FlowFormatter.kind(of: Data("<html></html>".utf8), mimeType: "text/html") == .html)
    #expect(FlowFormatter.kind(of: Data([0, 1, 2, 3]), mimeType: "application/octet-stream") == .binary)
    #expect(FlowFormatter.kind(of: Data(), mimeType: "text/plain") == .empty)
    #expect(FlowFormatter.prettyJSON(Data(#"{"b":[1,2],"a":"x/y"}"#.utf8)) == "{\n  \"a\" : \"x/y\",\n  \"b\" : [\n    1,\n    2\n  ]\n}")
    #expect(FlowFormatter.prettyJSON(Data("nope".utf8)) == nil)
}

@Test func saveNamesAndSizesAreReadable() {
    var item = HTTPFlow(id: 1, scheme: "https", host: "cdn.example.com", port: 443, method: "GET", path: "/img/logo.png?v=2")
    #expect(FlowFormatter.suggestedFileName(for: item) == "logo.png")
    item.path = "/api/users"
    item.responseHeaders = [HTTPHeader("Content-Type", "application/json")]
    item.responseBody = Data("{}".utf8)
    #expect(FlowFormatter.suggestedFileName(for: item) == "users.json")
    #expect(FlowFormatter.sizeText(512) == "512 B" && FlowFormatter.sizeText(2048) == "2.0 KB")
    #expect(FlowFormatter.durationText(0.0345) == "34 ms" || FlowFormatter.durationText(0.0345) == "35 ms")
}

@Test func httpColumnsAreAConfigurableLayout() throws {
    var layout = HTTPColumnLayout()
    #expect(layout.visible == [.status, .method, .host, .path, .app, .type, .size, .duration])
    layout.setVisible(.path, false)
    #expect(layout.visible.contains(.path))   // the URL cannot be hidden
    layout.setVisible(.time, true)
    layout.move(.time, to: .status)
    #expect(layout.visible.first == .time)
    #expect(try #require(HTTPColumnLayout(json: layout.json)) == layout)
}
