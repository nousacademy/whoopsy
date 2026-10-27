import Foundation
import Whoopsy

// MARK: - 16. The build stamp — which bundle wrote this capture

/// The block that keeps a capture honest about *which* binary produced it.
///
/// **A sideloaded bundle's file dates are the zip epoch**, so the first version of this stamp reported
/// `1979-11-30` for every build and identified nothing — measured on 2026-10-26, after two rounds of
/// diagnosis chased a symptom that was a stale install. What actually changes per link is the Mach-O
/// `LC_UUID`, and that is what this reads. The assertions here use a synthetic header rather than a
/// real binary so the parser's offsets are pinned without a build artefact to depend on.
enum AppBuildStampTests {
    static func run() async throws {
        /// A minimal 64-bit little-endian Mach-O: `MH_MAGIC_64`, one load command, and that command
        /// is `LC_UUID` carrying `bytes`.
        func machO(uuid bytes: [UInt8]) -> Data {
            var data = Data()
            data.append(contentsOf: [0xCF, 0xFA, 0xED, 0xFE])   // magic, little-endian
            data.append(contentsOf: [0, 0, 0, 0])                // cputype
            data.append(contentsOf: [0, 0, 0, 0])                // cpusubtype
            data.append(contentsOf: [0, 0, 0, 0])                // filetype
            data.append(contentsOf: [1, 0, 0, 0])                // ncmds = 1
            data.append(contentsOf: [0, 0, 0, 0])                // sizeofcmds
            data.append(contentsOf: [0, 0, 0, 0])                // flags
            data.append(contentsOf: [0, 0, 0, 0])                // reserved
            data.append(contentsOf: [0x1B, 0, 0, 0])             // LC_UUID
            data.append(contentsOf: [24, 0, 0, 0])               // cmdsize: 8 header + 16 uuid
            data.append(contentsOf: bytes)
            return data
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whoopsy-uuid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let bytes: [UInt8] = Array(0...15)
        try machO(uuid: bytes).write(to: url)
        assertTest(
            AppBuildStamp.machOUUID(of: url)
                == "00010203-0405-0607-0809-0A0B0C0D0E0F",
            "The stamp reads the debug dylib's **Mach-O `LC_UUID`** — the one value that changes on "
                + "every link and survives sideload re-signing "
                + "(\(AppBuildStamp.machOUUID(of: url) ?? "nil"))")

        try Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                  0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
                  0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
                  0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F]).write(to: url)
        assertTest(
            AppBuildStamp.machOUUID(of: url) == nil,
            "…and a file that is not a Mach-O answers `nil` rather than a plausible UUID read from "
                + "whatever happens to sit at those offsets — a diagnostic must never be able to "
                + "invent the one value it exists to report")
    }
}
