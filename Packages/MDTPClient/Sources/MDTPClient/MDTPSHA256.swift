import Foundation

/// Implementacion de SHA-256 sin dependencias externas.
public enum MDTPSHA256 {
    /// Calcula el SHA-256 de un bloque de bytes.
    public static func hash(_ data: Data) -> Data {
        var context = Context()
        context.update(data)
        return context.finalize()
    }

    /// Calcula el SHA-256 de un arreglo de bytes.
    public static func hash(_ bytes: [UInt8]) -> Data {
        var context = Context()
        context.update(bytes)
        return context.finalize()
    }

    /// Calcula el SHA-256 de un archivo leyendolo por bloques.
    public static func hash(fileAt url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var context = Context()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            context.update(chunk)
        }
        return context.finalize()
    }

    /// Estado incremental de SHA-256.
    public struct Context: Sendable {
        private var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        private var buffer: [UInt8] = []
        private var totalBytes: UInt64 = 0

        /// Crea un contexto vacio.
        public init() {
            buffer.reserveCapacity(64)
        }

        /// Agrega datos al hash sin finalizarlo.
        public mutating func update(_ data: Data) {
            update([UInt8](data))
        }

        /// Agrega bytes al hash sin finalizarlo.
        public mutating func update(_ bytes: [UInt8]) {
            totalBytes &+= UInt64(bytes.count)
            buffer.append(contentsOf: bytes)

            var offset = 0
            while buffer.count - offset >= 64 {
                processBlock(buffer, offset: offset)
                offset += 64
            }
            if offset > 0 {
                buffer.removeFirst(offset)
            }
        }

        /// Finaliza el calculo y devuelve los 32 bytes del SHA-256.
        public mutating func finalize() -> Data {
            let bitLength = totalBytes &* 8

            buffer.append(0x80)
            while buffer.count % 64 != 56 {
                buffer.append(0)
            }
            for shift in stride(from: 56, through: 0, by: -8) {
                buffer.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
            }

            var offset = 0
            while offset < buffer.count {
                processBlock(buffer, offset: offset)
                offset += 64
            }

            var digest = Data(capacity: 32)
            for word in state {
                digest.append(UInt8((word >> 24) & 0xff))
                digest.append(UInt8((word >> 16) & 0xff))
                digest.append(UInt8((word >> 8) & 0xff))
                digest.append(UInt8(word & 0xff))
            }
            return digest
        }

        private mutating func processBlock(_ block: [UInt8], offset: Int) {
            var w = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let base = offset + index * 4
                w[index] =
                    (UInt32(block[base]) << 24)
                    | (UInt32(block[base + 1]) << 16)
                    | (UInt32(block[base + 2]) << 8)
                    | UInt32(block[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(w[index - 15], by: 7)
                    ^ rotateRight(w[index - 15], by: 18)
                    ^ (w[index - 15] >> 3)
                let s1 = rotateRight(w[index - 2], by: 17)
                    ^ rotateRight(w[index - 2], by: 19)
                    ^ (w[index - 2] >> 10)
                w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
            }

            var a = state[0]
            var b = state[1]
            var c = state[2]
            var d = state[3]
            var e = state[4]
            var f = state[5]
            var g = state[6]
            var h = state[7]

            for index in 0..<64 {
                let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choice = (e & f) ^ ((~e) & g)
                let temp1 = h &+ sum1 &+ choice &+ MDTPSHA256.constants[index] &+ w[index]
                let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = sum0 &+ majority

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
        }

        private func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
            (value >> amount) | (value << (32 - amount))
        }
    }

    private static let constants: [UInt32] = [
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
}
