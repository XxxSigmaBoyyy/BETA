import Foundation
import Network

// MARK: - AorusQuicProbePacket
//
// A Hysteria 2 server is QUIC. It listens on UDP and nothing at all answers a TCP connect to it,
// healthy or not — so the handshake timing every other row shows could not be measured for one,
// and those rows sat in the list with no number while their neighbours had one.
//
// This measures them properly, using the one thing the protocol guarantees an answer to.
// RFC 9000 §6: an endpoint that receives a packet naming a version it does not support MUST reply
// with a Version Negotiation packet. So the probe sends a long-header packet naming a version no
// implementation has, and times the reply. No credential is involved and no connection is made:
// it is the QUIC equivalent of the TCP handshake the other rows are timed by.
//
// Three details are not decoration, and each was read out of the server this build talks to
// (quic-go, as Xray's Hysteria transport listens with it) rather than assumed:
//
//   * The packet must be at least 1200 bytes. A server drops a shorter unknown-version packet
//     without answering — measured, not inferred: 1200 bytes is answered and 1199 is not.
//   * The reply echoes our two connection ids back, swapped. They are random per probe, so
//     checking them is what stops an unrelated datagram arriving on the socket from being
//     timed as if it were the server's answer.
//   * Version Negotiation is on by default and Xray's Hysteria listener does not turn it off.
//
// A server whose operator turned on Salamander obfuscation cannot be measured this way: every
// packet it receives is unwrapped with a key derived from a password, so a plain probe is
// discarded as noise. Those rows stay unmeasured, which is what they were before.
enum AorusQuicProbePacket {
    /// A version number no implementation supports, which is the whole point: it is what forces
    /// the server to answer. The pattern is one of the reserved "greased" versions, chosen so it
    /// cannot collide with a real one that appears later.
    private static let unsupportedVersion: [UInt8] = [0x0a, 0x0a, 0x0a, 0x0a]
    /// Connection ids are eight bytes here. The specification allows up to twenty; eight is what
    /// every implementation handles and is long enough that two probes in one sweep cannot
    /// collide by chance.
    static let connectionIdLength = 8
    /// The minimum a server will look at. Below this the packet is discarded in silence.
    static let minimumSize = 1200

    /// One probe: the datagram to send, and the two ids the answer has to carry back.
    struct Probe {
        let datagram: Data
        let destinationId: Data
        let sourceId: Data
    }

    static func make() -> Probe {
        let destinationId = Data((0 ..< connectionIdLength).map { _ in UInt8.random(in: 0 ... 255) })
        let sourceId = Data((0 ..< connectionIdLength).map { _ in UInt8.random(in: 0 ... 255) })

        var datagram = Data()
        // Long header form, fixed bit set. The four bits below them are protected in a real
        // packet and ignored in an unknown-version one, so they carry nothing.
        datagram.append(0xc0)
        datagram.append(contentsOf: unsupportedVersion)
        datagram.append(UInt8(destinationId.count))
        datagram.append(destinationId)
        datagram.append(UInt8(sourceId.count))
        datagram.append(sourceId)
        if datagram.count < minimumSize {
            datagram.append(Data(repeating: 0x00, count: minimumSize - datagram.count))
        }
        return Probe(datagram: datagram, destinationId: destinationId, sourceId: sourceId)
    }

    /// Whether `reply` is the Version Negotiation packet this probe asked for.
    ///
    /// A Version Negotiation packet is a long header whose version field is four zero bytes,
    /// followed by the connection ids the sender used — swapped, so our source comes back as its
    /// destination. Both are checked: the shape alone would accept any stray datagram that
    /// happened to start with the right bytes, and the ids are what make the answer ours.
    static func isAnswer(_ reply: Data, to probe: Probe) -> Bool {
        let bytes = [UInt8](reply)
        // Header byte, four version bytes, one length byte: the shortest thing worth reading.
        guard bytes.count >= 6 else { return false }
        guard bytes[0] & 0x80 != 0 else { return false }
        guard bytes[1] == 0, bytes[2] == 0, bytes[3] == 0, bytes[4] == 0 else { return false }

        let destinationLength = Int(bytes[5])
        let destinationStart = 6
        let destinationEnd = destinationStart + destinationLength
        guard destinationEnd < bytes.count else { return false }
        let sourceLength = Int(bytes[destinationEnd])
        let sourceStart = destinationEnd + 1
        let sourceEnd = sourceStart + sourceLength
        guard sourceEnd <= bytes.count else { return false }

        let echoedDestination = Data(bytes[destinationStart ..< destinationEnd])
        let echoedSource = Data(bytes[sourceStart ..< sourceEnd])
        return echoedDestination == probe.sourceId && echoedSource == probe.destinationId
    }
}

// MARK: - AorusQuicLatencyProbe

/// The round trip to a QUIC server's own address, timed.
///
/// Measured from the same moment as the TCP probe beside it — the call that starts the connection,
/// so the name resolution both of them have to do is inside both figures. Otherwise a Hysteria row
/// would read faster than a VLESS row on the same host for no reason but which probe drew it, and
/// the list is ordered by these numbers.
enum AorusQuicLatencyProbe {
    /// Concurrent for the same reason the TCP one is: a sweep measures every server at once, and
    /// on a serial queue each reply waits behind the ones before it and is timed with that wait
    /// inside it.
    private static let queue = DispatchQueue(
        label: "com.aorusgram.uservpn.quiclatency",
        qos: .utility,
        attributes: .concurrent
    )

    /// Milliseconds, or nil when nothing answered in time.
    static func measure(host: String, port: Int, timeout: TimeInterval, completion: @escaping (Double?) -> Void) {
        guard !host.isEmpty, port > 0, let networkPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            completion(nil)
            return
        }
        let probe = AorusQuicProbePacket.make()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: networkPort, using: .udp)
        let state = AorusProbeCompletion(cancel: { connection.cancel() }, completion: completion)
        let started = Date()

        func receive() {
            connection.receiveMessage { data, _, _, error in
                if let data, AorusQuicProbePacket.isAnswer(data, to: probe) {
                    state.finish(Date().timeIntervalSince(started) * 1000.0)
                    return
                }
                guard error == nil else {
                    state.finish(nil)
                    return
                }
                // Something else arrived on the socket. Keep waiting for ours rather than
                // reporting a measurement of whatever that was.
                receive()
            }
        }

        connection.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                connection.send(content: probe.datagram, completion: .contentProcessed { error in
                    if error != nil {
                        state.finish(nil)
                    }
                })
                receive()
            case .failed, .cancelled:
                state.finish(nil)
            case .waiting:
                // The path is not viable right now. Retrying inside a probe would time the retry.
                state.finish(nil)
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: self.queue)
        self.queue.asyncAfter(deadline: .now() + timeout) {
            state.finish(nil)
        }
    }
}

/// Guarantees the completion runs once and the socket is always closed, however the probe ends —
/// one that leaks a connection per server is one that runs out of them.
final class AorusProbeCompletion {
    private let lock = NSLock()
    private var finished = false
    private let cancel: () -> Void
    private let completion: (Double?) -> Void

    init(cancel: @escaping () -> Void, completion: @escaping (Double?) -> Void) {
        self.cancel = cancel
        self.completion = completion
    }

    func finish(_ value: Double?) {
        self.lock.lock()
        if self.finished {
            self.lock.unlock()
            return
        }
        self.finished = true
        self.lock.unlock()
        self.cancel()
        self.completion(value)
    }
}
