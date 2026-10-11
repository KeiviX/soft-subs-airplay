import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
    /// True when the request came from this Mac rather than from the TV or another device.
    var isLoopback: Bool

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func text(_ string: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": contentType], body: Data(string.utf8))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        .json(["ok": false, "error": message], status: status)
    }
}

/// A small HTTP/1.1 server. Each connection carries one request and is closed after the response,
/// which AVPlayer and the TV both handle fine.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    var onFailure: (@Sendable (String) -> Void)?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "softsubs.http", attributes: .concurrent)
    private let handler: Handler

    private enum ParseResult {
        case complete(HTTPRequest)
        case incomplete
        case invalid
    }

    init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.handler = handler
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onFailure?("Server stopped: \(error.localizedDescription)") }
        }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer, from: connection) {
            case .complete(let request):
                Task {
                    let response = await self.handler(request)
                    self.send(response, for: request, on: connection)
                }
            case .incomplete where !isComplete && error == nil && buffer.count < 64 << 20:
                self.read(connection, buffer: buffer)
            default:
                connection.cancel()
            }
        }
    }

    private static func parse(_ buffer: Data, from connection: NWConnection) -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let bodyStart = headerEnd.upperBound
        let length = Int(headers["content-length"] ?? "") ?? 0
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))

        let components = URLComponents(string: String(requestLine[1]))
        var query: [String: String] = [:]
        components?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }

        return .complete(HTTPRequest(
            method: String(requestLine[0]),
            path: components?.path ?? "/",
            query: query,
            headers: headers,
            body: body,
            isLoopback: isLoopback(connection)
        ))
    }

    private static func isLoopback(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || (address.asIPv4?.isLoopback ?? false)
        default: return false
        }
    }

    private func send(_ response: HTTPResponse, for request: HTTPRequest, on connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Access-Control-Allow-Headers"] = "Content-Type"
        headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"

        var head = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"

        var data = Data(head.utf8)
        if request.method != "HEAD" { data.append(response.body) }
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
