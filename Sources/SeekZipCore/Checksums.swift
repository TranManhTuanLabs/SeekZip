import Foundation

/// Checksums, computed natively in Swift (M5).
///
/// No CryptoKit dependency: CryptoKit is Apple-only, and the core must
/// also build on the Linux Swift toolchain used for local tests. Both
/// algorithms here are public-domain specifications (CRC-32/IEEE and
/// FIPS 180-4 SHA-256), implemented from the spec and pinned by known
/// test vectors in `CoreTests` — they are not copied from any archive
/// tool. The streaming accumulators let `verify` hash a 10 GB entry
/// without loading it into memory.

/// CRC-32 (IEEE 802.3, polynomial 0xEDB88320) — the checksum 7-Zip
/// reports per entry in `7zz l -slt` (`CRC = …`).
public enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    /// Checksum of `data` as an 8-digit uppercase hex string, the
    /// same form `7zz` prints (`CBF43926` for `"123456789"`).
    public static func hex(of data: Data) -> String {
        String(format: "%08X", checksum(of: data))
    }

    public static func checksum(of data: Data) -> UInt32 {
        var acc = Accumulator()
        acc.update(data)
        return acc.finalize()
    }

    /// Incremental CRC-32: feed chunks as they stream in, then
    /// `finalize()`. Feeding the same bytes in any chunking gives the
    /// same result.
    public struct Accumulator {
        private var crc: UInt32 = 0xFFFFFFFF

        public init() {}

        public mutating func update(_ data: Data) {
            for byte in data {
                crc = CRC32.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }

        public func finalize() -> UInt32 { crc ^ 0xFFFFFFFF }

        public func hex() -> String { String(format: "%08X", finalize()) }
    }
}

/// SHA-256 (FIPS 180-4), pure Swift. Used for on-demand entry hashes
/// (`verify --sha256`); the listing's CRC-32 is the cheap per-entry
/// check, SHA-256 is the strong one.
public enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hex(of data: Data) -> String {
        var acc = Accumulator()
        acc.update(data)
        return acc.finalizeHex()
    }

    /// Incremental SHA-256, same chunking guarantee as `CRC32`.
    public struct Accumulator {
        private var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        private var buffer = Data()
        private var totalBytes: UInt64 = 0

        public init() {}

        public mutating func update(_ data: Data) {
            totalBytes += UInt64(data.count)
            buffer.append(data)
            while buffer.count >= 64 {
                compress(Data(buffer.prefix(64)))
                buffer.removeFirst(64)
            }
        }

        public mutating func finalizeHex() -> String {
            finalize().map { String(format: "%02x", $0) }.joined()
        }

        public mutating func finalize() -> [UInt8] {
            // Padding: 0x80, zeros, then the 64-bit big-endian bit length.
            var tail = buffer
            let bitLength = totalBytes * 8
            tail.append(0x80)
            while tail.count % 64 != 56 { tail.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) {
                tail.append(UInt8((bitLength >> shift) & 0xFF))
            }
            var offset = tail.startIndex
            while offset < tail.endIndex {
                compress(Data(tail[offset..<tail.index(offset, offsetBy: 64)]))
                offset = tail.index(offset, offsetBy: 64)
            }
            buffer.removeAll()
            return h.flatMap { word in
                [UInt8((word >> 24) & 0xFF), UInt8((word >> 16) & 0xFF),
                 UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF)]
            }
        }

        private mutating func compress(_ block: Data) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = block.startIndex + i * 4
                w[i] = (UInt32(block[o]) << 24) | (UInt32(block[o + 1]) << 16)
                    | (UInt32(block[o + 2]) << 8) | UInt32(block[o + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) =
                (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ SHA256.k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b
            h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f
            h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }

        private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
            (x >> n) | (x << (32 - n))
        }
    }
}
