import Foundation

/// Stable workout ids for watch sync (SPEC.md F10).
///
/// A WorkoutKit `WorkoutPlan` is identified by a UUID. Deriving it from the
/// session id (RFC 4122 version 5, name-based with SHA-1) gives the same UUID
/// on every sync and every device, so the app can find what it scheduled
/// before and replace it instead of adding a duplicate, and a completed
/// workout maps back to its session.
public enum WatchSyncID {
    /// The namespace for this app's workout UUIDs (a fixed random UUID).
    public static let namespace = UUID(uuidString: "3123996D-4364-4BFF-A310-8E2B3278B220")!

    /// The workout UUID for a session id.
    public static func uuid(forSessionID sessionID: String) -> UUID {
        uuidV5(namespace: namespace, name: sessionID)
    }

    /// RFC 4122 version-5 UUID of `name` (UTF-8) in `namespace`.
    public static func uuidV5(namespace: UUID, name: String) -> UUID {
        let ns = namespace.uuid
        var bytes: [UInt8] = [ns.0, ns.1, ns.2, ns.3, ns.4, ns.5, ns.6, ns.7,
                              ns.8, ns.9, ns.10, ns.11, ns.12, ns.13, ns.14, ns.15]
        bytes += Array(name.utf8)
        var h = SHA1.digest(bytes)
        h[6] = (h[6] & 0x0F) | 0x50 // version 5
        h[8] = (h[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
                           h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
    }
}

/// SHA-1 (FIPS 180-4), only for name-based UUIDs. Not for security: CoachCore
/// is Foundation-only, and Foundation has no hash API on Linux.
enum SHA1 {
    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x6745_2301, h1: UInt32 = 0xEFCD_AB89, h2: UInt32 = 0x98BA_DCFE
        var h3: UInt32 = 0x1032_5476, h4: UInt32 = 0xC3D2_E1F0
        var m = message
        let bitLength = UInt64(message.count) &* 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }

        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(m[j]) << 24 | UInt32(m[j + 1]) << 16 | UInt32(m[j + 2]) << 8 | UInt32(m[j + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotl(b, 30); b = a; a = t
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }
        var out: [UInt8] = []
        for v in [h0, h1, h2, h3, h4] {
            out += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        }
        return out
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { x << n | x >> (32 - n) }
}
