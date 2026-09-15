import Foundation

// The QUIC probe that gives a Hysteria 2 row its handshake figure. Every rule below was measured
// against the server implementation this build actually talks to — quic-go, which is what Xray's
// Hysteria transport listens with — by firing this exact packet at a listener started the same way
// the Hysteria hub starts one. A 1200-byte probe is answered with Version Negotiation carrying our
// connection ids back; a 1199-byte one is not answered at all.

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("AorusQuicProbe test failed: \(message)\n", stderr)
        exit(1)
    }
}

/// A Version Negotiation packet as the server composes it: a long header, a zero version, then the
/// sender's ids swapped, then the versions it does support.
private func versionNegotiation(
    destinationId: Data,
    sourceId: Data,
    versions: [UInt8] = [0x00, 0x00, 0x00, 0x01]
) -> Data {
    var reply = Data()
    reply.append(0xc0)
    reply.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
    reply.append(UInt8(destinationId.count))
    reply.append(destinationId)
    reply.append(UInt8(sourceId.count))
    reply.append(sourceId)
    reply.append(contentsOf: versions)
    return reply
}

private func buildsThePacketTheServerWillAnswer() {
    let probe = AorusQuicProbePacket.make()
    let bytes = [UInt8](probe.datagram)

    // Measured, not inferred: at 1199 bytes the server answers nothing at all.
    require(probe.datagram.count == 1200, "the packet is padded to the minimum a server will read")
    require(AorusQuicProbePacket.minimumSize == 1200, "and that minimum is the one the server uses")

    require(bytes[0] & 0x80 != 0, "the long header form bit is set")
    require(bytes[0] & 0x40 != 0, "and so is the fixed bit")
    // The version has to be one no implementation supports — that is what obliges the server to
    // answer. A supported version would start a real handshake instead.
    require(Array(bytes[1 ... 4]) == [0x0a, 0x0a, 0x0a, 0x0a], "the version is a reserved one")

    require(Int(bytes[5]) == AorusQuicProbePacket.connectionIdLength, "the destination id length is written")
    let destinationEnd = 6 + AorusQuicProbePacket.connectionIdLength
    require(Data(bytes[6 ..< destinationEnd]) == probe.destinationId, "and the id itself")
    require(Int(bytes[destinationEnd]) == AorusQuicProbePacket.connectionIdLength, "the source id length is written")
    let sourceEnd = destinationEnd + 1 + AorusQuicProbePacket.connectionIdLength
    require(Data(bytes[(destinationEnd + 1) ..< sourceEnd]) == probe.sourceId, "and that id too")
    require(bytes[sourceEnd...].allSatisfy { $0 == 0 }, "the rest is padding")

    // Two probes in one sweep must be distinguishable, or one server's answer could be timed as
    // another's.
    let other = AorusQuicProbePacket.make()
    require(other.destinationId != probe.destinationId, "each probe uses its own ids")
    require(other.sourceId != probe.sourceId, "both of them")
    require(probe.destinationId != probe.sourceId, "and the two ids of one probe differ")
}

private func acceptsTheAnswerAndNothingElse() {
    let probe = AorusQuicProbePacket.make()

    // The server swaps the ids: our source comes back as its destination.
    let answer = versionNegotiation(destinationId: probe.sourceId, sourceId: probe.destinationId)
    require(AorusQuicProbePacket.isAnswer(answer, to: probe), "the server's answer is recognised")

    // Not swapped is not an answer to this probe.
    require(!AorusQuicProbePacket.isAnswer(
        versionNegotiation(destinationId: probe.destinationId, sourceId: probe.sourceId), to: probe),
        "ids that are not swapped are refused")

    // Another probe's answer arriving on this socket must not be timed as this one's. This is the
    // case the ids exist for.
    let stranger = AorusQuicProbePacket.make()
    require(!AorusQuicProbePacket.isAnswer(
        versionNegotiation(destinationId: stranger.sourceId, sourceId: stranger.destinationId), to: probe),
        "another probe's answer is not mistaken for ours")

    // A long header that is not Version Negotiation — a real Initial, say — is not an answer.
    var initial = Data()
    initial.append(0xc0)
    initial.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
    initial.append(UInt8(probe.sourceId.count))
    initial.append(probe.sourceId)
    initial.append(UInt8(probe.destinationId.count))
    initial.append(probe.destinationId)
    require(!AorusQuicProbePacket.isAnswer(initial, to: probe), "a supported-version packet is not an answer")

    // A short header packet is not one either.
    var short = versionNegotiation(destinationId: probe.sourceId, sourceId: probe.destinationId)
    short[0] = 0x40
    require(!AorusQuicProbePacket.isAnswer(short, to: probe), "a short header is not an answer")

    // Truncated datagrams must be refused rather than read past the end. Every prefix of a real
    // answer is fed in, which is what a path that reads lengths out of the packet has to survive.
    let full = versionNegotiation(destinationId: probe.sourceId, sourceId: probe.destinationId)
    for length in 0 ..< full.count {
        _ = AorusQuicProbePacket.isAnswer(full.prefix(length), to: probe)
    }
    require(!AorusQuicProbePacket.isAnswer(Data(), to: probe), "an empty datagram is refused")
    // Header, version, both length bytes and both ids — one byte short of the second id being
    // complete. The version list after it is the server's own and is not read, so the cut has to
    // be made inside the ids to test anything.
    let throughIds = 1 + 4 + 1 + probe.sourceId.count + 1 + probe.destinationId.count
    require(!AorusQuicProbePacket.isAnswer(full.prefix(throughIds - 1), to: probe),
            "an answer cut short of its last id byte is refused")
    require(AorusQuicProbePacket.isAnswer(full.prefix(throughIds), to: probe),
            "and one that ends exactly at the ids is accepted")

    // A length byte that claims more than the datagram holds must not be believed.
    var lying = full
    lying[5] = 0xff
    require(!AorusQuicProbePacket.isAnswer(lying, to: probe), "an impossible id length is refused")
    var lyingSource = full
    lyingSource[6 + probe.sourceId.count] = 0xff
    require(!AorusQuicProbePacket.isAnswer(lyingSource, to: probe), "an impossible source id length is refused")

    // The versions the server lists are its own business: any number of them, including none.
    require(AorusQuicProbePacket.isAnswer(
        versionNegotiation(destinationId: probe.sourceId, sourceId: probe.destinationId, versions: []), to: probe),
        "an answer that lists no versions is still an answer")
    require(AorusQuicProbePacket.isAnswer(
        versionNegotiation(destinationId: probe.sourceId, sourceId: probe.destinationId,
                           versions: [0, 0, 0, 1, 0, 0, 0, 2]), to: probe),
        "and so is one that lists several")
}

@main
private enum AorusQuicProbeTests {
    static func main() {
        buildsThePacketTheServerWillAnswer()
        acceptsTheAnswerAndNothingElse()
        print("AorusQuicProbe tests: OK")
    }
}
