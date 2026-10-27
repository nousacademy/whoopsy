import Foundation

/// One line identifying the build that is actually running, written to `capture.txt` at launch.
///
/// **This exists because a capture cannot otherwise say which bundle made it.** Two rounds of
/// diagnosis on 2026-10-26 chased a symptom whose real cause was that the phone was running the
/// previous IPA: the log showed features from one build and none from the next, and nothing in it
/// dated the binary. A version string would not help — every sideloaded build carries the same
/// `CFBundleVersion` — so this stamps the artefact itself: the debug dylib that holds the code, by
/// byte size and Mach-O UUID, both of which change on every link. A capture whose stamp does not match
/// the IPA that was just installed is a capture of the wrong build, and that is a fact worth one line
/// at startup.
public enum AppBuildStamp {

    /// `"version=<short>(<build>) dylib=<bytes>B uuid=<LC_UUID>"`.
    ///
    /// **The modification time is deliberately not reported.** A sideloaded bundle carries the zip
    /// epoch, so every build's files claim to date from 1979 — measured on 2026-10-26, when the first
    /// stamp this file wrote was `exe=1979-11-30…`, which identifies nothing. What does identify a
    /// link is the Mach-O `LC_UUID` and the byte size, and both change on every build.
    public static func describe(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let dylib = bundle.bundleURL.appendingPathComponent("WhoopsyApp.debug.dylib")
        let size = (try? FileManager.default.attributesOfItem(atPath: dylib.path))?[.size] as? Int
        return "version=\(short)(\(build)) dylib=\(size.map { "\($0)B" } ?? "-") "
            + "uuid=\(machOUUID(of: dylib) ?? "-")"
    }

    /// The 16-byte `LC_UUID` payload of a 64-bit little-endian Mach-O, as the canonical UUID string.
    ///
    /// A minimal reader rather than a dependency: the header is 32 bytes, the load commands follow it,
    /// and the one to find is identified by its command word. Anything unexpected answers `nil` — this
    /// is a diagnostic and must never be able to fail a launch.
    public static func machOUUID(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 32 else {
            return nil
        }
        func u32(_ offset: Int) -> UInt32? {
            guard offset + 3 < data.count else { return nil }
            let base = data.startIndex + offset
            return UInt32(data[base]) | (UInt32(data[base + 1]) << 8)
                | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
        }
        guard u32(0) == 0xFEED_FACF else { return nil }   // MH_MAGIC_64, little-endian
        guard let commandCount = u32(16) else { return nil }
        var offset = 32
        for _ in 0..<commandCount {
            guard let command = u32(offset), let size = u32(offset + 4), size >= 8 else { return nil }
            if command == 0x1B, size >= 24, offset + 23 < data.count {   // LC_UUID
                let base = data.startIndex + offset + 8
                let bytes = [UInt8](data[base..<(base + 16)])
                let hex = bytes.map { String(format: "%02X", $0) }.joined()
                return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-"
                    + "\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-"
                    + "\(hex.dropFirst(20))"
            }
            offset += Int(size)
        }
        return nil
    }
}
