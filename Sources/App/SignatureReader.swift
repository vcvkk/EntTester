import Foundation

/// Reads this binary's own embedded entitlements from the Mach-O code signature
/// (LC_CODE_SIGNATURE -> SuperBlob -> 0xfade7171). No private API. Reflects the
/// final on-device signature after re-signing.
enum SignatureReader {
    static let entitlements: [String: Any] = read()

    static func read() -> [String: Any] {
        guard let path = Bundle.main.executablePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [:] }
        return [UInt8](data).withUnsafeBufferPointer { buf in parse(buf) } ?? [:]
    }

    private static func be32(_ b: UnsafeBufferPointer<UInt8>, _ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= b.count else { return nil }
        return (UInt32(b[o]) << 24) | (UInt32(b[o+1]) << 16) | (UInt32(b[o+2]) << 8) | UInt32(b[o+3])
    }
    private static func le32(_ b: UnsafeBufferPointer<UInt8>, _ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= b.count else { return nil }
        return UInt32(b[o]) | (UInt32(b[o+1]) << 8) | (UInt32(b[o+2]) << 16) | (UInt32(b[o+3]) << 24)
    }

    private static let FAT_MAGIC: UInt32 = 0xcafebabe
    private static let FAT_CIGAM: UInt32 = 0xbebafeca
    private static let MH_MAGIC_64: UInt32 = 0xfeedfacf
    private static let LC_CODE_SIGNATURE: UInt32 = 0x1d
    private static let CPU_ARM64: UInt32 = 0x0100000c
    private static let CS_SUPER: UInt32 = 0xfade0cc0
    private static let CS_ENTS: UInt32 = 0xfade7171

    private static func parse(_ b: UnsafeBufferPointer<UInt8>) -> [String: Any]? {
        guard let magic = be32(b, 0) else { return nil }
        var slice = 0
        if magic == FAT_MAGIC || magic == FAT_CIGAM {
            guard let n = be32(b, 4) else { return nil }
            var chosen: Int?
            for i in 0..<Int(n) {
                let base = 8 + i * 20
                guard let cpu = be32(b, base), let off = be32(b, base + 8) else { break }
                if cpu == CPU_ARM64 { chosen = Int(off); break }
                if chosen == nil { chosen = Int(off) }
            }
            guard let s = chosen else { return nil }
            slice = s
        }
        guard le32(b, slice) == MH_MAGIC_64, let ncmds = le32(b, slice + 16) else { return nil }
        var cur = slice + 32
        for _ in 0..<Int(ncmds) {
            guard let cmd = le32(b, cur), let sz = le32(b, cur + 4), sz >= 8 else { return nil }
            if cmd == LC_CODE_SIGNATURE {
                guard let off = le32(b, cur + 8) else { return nil }
                return superblob(b, slice + Int(off))
            }
            cur += Int(sz)
        }
        return nil
    }

    private static func superblob(_ b: UnsafeBufferPointer<UInt8>, _ start: Int) -> [String: Any]? {
        guard be32(b, start) == CS_SUPER, let count = be32(b, start + 8) else { return nil }
        var idx = start + 12
        for _ in 0..<Int(count) {
            guard be32(b, idx) != nil, let off = be32(b, idx + 4) else { return nil }
            let blob = start + Int(off)
            if be32(b, blob) == CS_ENTS, let len = be32(b, blob + 4), len > 8 {
                let p = blob + 8, l = Int(len) - 8
                guard p + l <= b.count else { return nil }
                let data = Data(bytes: b.baseAddress!.advanced(by: p), count: l)
                return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
            }
            idx += 8
        }
        return nil
    }
}
