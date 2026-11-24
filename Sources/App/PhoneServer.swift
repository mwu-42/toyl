// Copied from Oyl (Sources/PhoneServer.swift), so the two phone pages are served the same careful way.
import Foundation
import Network
import SystemConfiguration

/// A request from the phone, as much HTTP as the remote needs: the method, the path and its query,
/// the headers (named in lower case), and a small body.
struct PhoneRequest: Equatable {
    var method: String
    var path: String
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var body = Data()

    /// The cookie named `name`, if it came.
    func cookie(_ name: String) -> String? {
        guard let cookies = headers["cookie"] else { return nil }
        for pair in cookies.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == name { return parts[1] }
        }
        return nil
    }

    /// The host it was sent to, without its port, in lower case.
    var host: String? {
        guard var host = headers["host"]?.lowercased() else { return nil }
        if host.hasPrefix("[") {
            host = String(host.dropFirst().prefix { $0 != "]" })
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    enum Parsed: Equatable {
        case incomplete, bad, tooLarge
        case complete(PhoneRequest)
    }

    // (Room in the body for a long check-in.)
    static let headLimit = 8192, bodyLimit = 16384

    /// What's come in so far, read as a request if it's all there.
    static func parse(_ data: Data) -> Parsed {
        let end = Data("\r\n\r\n".utf8)
        guard let split = data.range(of: end) else { return data.count > headLimit ? .tooLarge : .incomplete }
        guard split.lowerBound <= headLimit, let head = String(data: data[..<split.lowerBound], encoding: .utf8) else {
            return split.lowerBound > headLimit ? .tooLarge : .bad
        }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1."), start[1].hasPrefix("/") else { return .bad }
        let target = start[1]
        var request = PhoneRequest(method: String(start[0]), path: String(target))
        if let mark = target.firstIndex(of: "?") {
            request.path = String(target[..<mark])
            for pair in target[target.index(after: mark)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
                request.query[parts[0]] = parts.count > 1 ? parts[1] : ""
            }
        }
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .bad }
            request.headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if request.headers["transfer-encoding"] != nil { return .bad }
        let length = request.headers["content-length"].map { Int($0) ?? -1 } ?? 0
        guard length >= 0 else { return .bad }
        guard length <= bodyLimit else { return .tooLarge }
        let bodyStart = split.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        request.body = data[bodyStart..<bodyStart + length]
        return .complete(request)
    }
}

/// What goes back: a status, its content's type and the content, and any more headers.
struct PhoneResponse: Equatable {
    var status: Int
    var type = "text/plain; charset=utf-8"
    var body = Data()
    var headers: [String: String] = [:]

    static func text(_ status: Int, _ text: String) -> PhoneResponse { PhoneResponse(status: status, body: Data(text.utf8)) }

    static func json(_ value: some Encodable, status: Int = 200) -> PhoneResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return PhoneResponse(status: status, type: "application/json", body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    static func redirect(_ to: String, headers: [String: String] = [:]) -> PhoneResponse {
        var response = PhoneResponse(status: 303, headers: headers)
        response.headers["Location"] = to
        return response
    }

    private static let reasons = [200: "OK", 303: "See Other", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                                  404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large", 421: "Misdirected Request",
                                  429: "Too Many Requests"]

    /// As it's sent: kept off other pages (framed, or read by their scripts) and out of caches.
    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        var all = ["Content-Type": type, "Content-Length": String(body.count), "Connection": "close", "Cache-Control": "no-store",
                   "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY", "Referrer-Policy": "no-referrer"]
        if type.hasPrefix("text/html") {
            all["Content-Security-Policy"] = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; "
                + "connect-src 'self'; manifest-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
        }
        all.merge(headers) { $1 }
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// The Mac on its network: its name there, its addresses, and whether a connection comes from a
/// device beside it (on the same Wi-Fi or Ethernet), or from one of your own on its tailnet (with
/// Tailscale running on both, from any network at all: a school's Wi-Fi that keeps devices apart,
/// or a phone's own data), rather than from farther off.
enum PhoneNetwork {
    struct Address {
        let interface: String
        let ipv6: Bool
        let bytes: [UInt8]
        let mask: [UInt8]

        var text: String {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return bytes.withUnsafeBytes { raw in
                inet_ntop(ipv6 ? AF_INET6 : AF_INET, raw.baseAddress, &buffer, socklen_t(buffer.count)).map { _ in String(cString: buffer) } ?? ""
            }
        }

        func holds(_ other: [UInt8]) -> Bool {
            other.count == bytes.count && zip(zip(bytes, mask), other).allSatisfy { pair, byte in pair.0 & pair.1 == byte & pair.1 }
        }
    }

    /// The Wi-Fi's and Ethernet's addresses (their interfaces are en0, en1…), up and running.
    static func addresses() -> [Address] { interfaceAddresses { $0.hasPrefix("en") } }

    /// The Mac's addresses on its tailnet, while Tailscale's running: on a tunnel (utun…), in the
    /// ranges Tailscale gives its devices.
    static func tailnetAddresses() -> [Address] { interfaceAddresses { $0.hasPrefix("utun") }.filter { isTailnet($0.bytes) } }

    /// In the ranges Tailscale gives its devices: 100.64.0.0/10, and fd7a:115c:a1e0::/48.
    static func isTailnet(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 { return bytes[0] == 100 && bytes[1] & 0xC0 == 64 }
        return bytes.count == 16 && Array(bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    }

    private static func interfaceAddresses(_ wanted: (String) -> Bool) -> [Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [Address] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            let name = String(cString: item.ifa_name)
            guard wanted(name), item.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  let address = item.ifa_addr, let mask = item.ifa_netmask else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                let masks = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                found.append(Address(interface: name, ipv6: false, bytes: bytes, mask: masks))
            case AF_INET6:
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                let masks = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                found.append(Address(interface: name, ipv6: true, bytes: bytes, mask: masks))
            default:
                continue
            }
        }
        return found
    }

    /// The Mac's name on the local network (as in "name.local"), from its Sharing settings.
    static var localName: String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" }
    }

    /// The Mac's own name, as its Sharing settings have it.
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "This Mac"
    }

    /// The names a request may be sent to here: the Mac's local name, its tailnet one, its
    /// addresses, and itself.
    static func hostNames(addresses: [Address] = addresses() + tailnetAddresses(), tailnetName: String? = nil) -> Set<String> {
        var names: Set<String> = ["localhost", "127.0.0.1", "::1"]
        if let localName { names.insert(localName.lowercased()) }
        if let tailnetName { names.insert(tailnetName.lowercased()) }
        for address in addresses { names.insert(address.text.lowercased()) }
        return names
    }

    /// A connection's from a device beside the Mac, on one of its Wi-Fi or Ethernet networks (or
    /// the Mac itself); or from one on its tailnet, come in on the Mac's own address there
    /// (`local`), so a device on the Wi-Fi with an address in Tailscale's ranges doesn't count.
    /// Not over any other VPN, or from the internet.
    static func isNearby(_ endpoint: NWEndpoint, local: NWEndpoint? = nil, addresses: [Address] = addresses(),
                         tailnet: [Address] = tailnetAddresses()) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        if let from = bytes(of: host), isTailnet(from) {
            guard case let .hostPort(here, _)? = local, let mine = bytes(of: here) else { return false }
            return tailnet.contains { $0.bytes == mine }
        }
        switch host {
        case let .ipv4(address):
            if address.isLoopback { return true }
            let bytes = [UInt8](address.rawValue)
            return addresses.contains { !$0.ipv6 && $0.holds(bytes) }
        case let .ipv6(address):
            if address.isLoopback { return true }
            if let v4 = address.asIPv4 { return isNearby(.hostPort(host: .ipv4(v4), port: 1), addresses: addresses) }
            let bytes = [UInt8](address.rawValue)
            // Link-local: from the link itself, if it's the Wi-Fi's or Ethernet's.
            if address.isLinkLocal {
                guard let interface = address.interface else { return addresses.contains { $0.ipv6 } }
                return interface.name.hasPrefix("en")
            }
            return addresses.contains { $0.ipv6 && $0.holds(bytes) }
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    /// An address's bytes (an IPv4 one by way of IPv6 as itself); nil for a name.
    private static func bytes(of host: NWEndpoint.Host) -> [UInt8]? {
        switch host {
        case let .ipv4(address): return [UInt8](address.rawValue)
        case let .ipv6(address): return address.asIPv4.map { [UInt8]($0.rawValue) } ?? [UInt8](address.rawValue)
        default: return nil
        }
    }

    /// The Mac's name on its tailnet ("name.tailnet.ts.net"), as Tailscale tells it; nil if it
    /// isn't installed or running. Asks its command line, so it's slow: off the main thread.
    static func askTailscale() -> String? {
        let tools = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let tool = tools.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["status", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let stuck = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: stuck)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stuck.cancel()
        return tailnetName(fromStatus: data)
    }

    /// The Mac's tailnet name from Tailscale's status, while it's running.
    static func tailnetName(fromStatus data: Data) -> String? {
        guard let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], status["BackendState"] as? String == "Running",
              let me = status["Self"] as? [String: Any], var name = me["DNSName"] as? String, !name.isEmpty else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name.lowercased()
    }
}

/// The remote's server: plain HTTP, one request a connection, from devices beside the Mac (or on
/// its tailnet, whose tunnel's encrypted) only (`PhoneNetwork.isNearby`). Each request's answered
/// on the main thread by `respond`.
final class PhoneServer: @unchecked Sendable {
    /// Listening, on which port; or why it couldn't.
    enum Status: Equatable {
        case starting, listening(UInt16), failed(String)
    }

    private let queue = DispatchQueue(label: "toyl phone server")
    private var listener: NWListener?
    private var open = 0
    private let respond: @MainActor (PhoneRequest) -> PhoneResponse
    private let status: @MainActor (Status) -> Void
    /// Listening on this address alone (to try it out), not every one the Mac has.
    private let only: NWEndpoint.Host?

    static let mostOpen = 16
    static let timeout: TimeInterval = 10

    init(only: NWEndpoint.Host? = nil, respond: @escaping @MainActor (PhoneRequest) -> PhoneResponse,
         status: @escaping @MainActor (Status) -> Void) {
        self.only = only
        self.respond = respond
        self.status = status
    }

    /// Listens on `port`, or the next free one of the few after it.
    func start(port: UInt16) {
        queue.async { self.listen(on: port, tries: 8) }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.status(status) } }
    }

    private func listen(on port: UInt16, tries: Int) {
        let parameters = NWParameters.tcp
        // Its own closed connections (and a listener just stopped) don't keep the port from it.
        parameters.allowLocalEndpointReuse = true
        guard let number = NWEndpoint.Port(rawValue: port) else {
            report(.failed("Couldn't listen"))
            return
        }
        if let only { parameters.requiredLocalEndpoint = .hostPort(host: only, port: number) }
        guard let listener = try? (only == nil ? NWListener(using: parameters, on: number) : NWListener(using: parameters)) else {
            report(.failed("Couldn't listen"))
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.report(.listening(listener.port?.rawValue ?? port))
            case let .failed(error):
                listener.cancel()
                self.listener = nil
                // Taken: the next.
                if tries > 1, case .posix(.EADDRINUSE) = error {
                    self.listen(on: port + 1, tries: tries - 1)
                } else {
                    self.report(.failed(error.localizedDescription))
                }
            default:
                break
            }
        }
        report(.starting)
        listener.start(queue: queue)
    }

    private func serve(_ connection: NWConnection) {
        guard open < Self.mostOpen else {
            connection.cancel()
            return
        }
        open += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Where it's from, and (for the tailnet) the address it came in on.
                guard PhoneNetwork.isNearby(connection.endpoint, local: connection.currentPath?.localEndpoint) else {
                    connection.cancel()
                    return
                }
                self?.receive(connection, Data())
            case .failed:
                connection.cancel()
            case .cancelled:
                self?.open -= 1
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.timeout) { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var received = received
            if let data { received.append(data) }
            switch PhoneRequest.parse(received) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(connection, received) }
            case .bad:
                self.send(.text(400, "Bad request"), on: connection)
            case .tooLarge:
                self.send(.text(413, "Too large"), on: connection)
            case let .complete(request):
                DispatchQueue.main.async {
                    let response = MainActor.assumeIsolated { self.respond(request) }
                    self.queue.async { self.send(response, on: connection) }
                }
            }
        }
    }

    private func send(_ response: PhoneResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}
