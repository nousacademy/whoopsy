import Foundation

/// An append-only text file in the app's Documents directory, written so a strap session can be read
/// on the phone itself rather than through a cable and Xcode's log window.
///
/// **This exists because unified logging is not a recording.** `os.log`'s `.debug` and `.info` go to a
/// small memory buffer and never reach disk; only `.notice` and above persist, which is why every
/// caller here logs at `.notice` as well as writing the line. The file is the copy that survives
/// leaving the app.
///
/// **Two files, not one, because the two contents answer for different things.** `capture.txt` follows
/// `docs/TODO.md` §5's rule — frame type, generation, payload length and the guard that refused a
/// frame, never a health value. `spo2-candidate.txt` is the one exception: the candidate probe's raw
/// bytes, which are the evidence a validation study needs and are explicitly labelled as candidate
/// evidence rather than a reading. Keeping them apart means the metadata file can be shared without
/// also sharing the nearest thing this app has to a stored oxygen figure.
///
/// Both files are capped and rotating: a walk or a night's drain cannot grow them without bound, and
/// the previous file is kept beside the current one as `<name>.1`.
public final class CaptureLog: @unchecked Sendable {
    /// The protocol-capture file, `Documents/capture.txt`.
    public static let shared = CaptureLog(fileName: "capture.txt")

    /// The SpO2 candidate probe's file, `Documents/spo2-candidate.txt`.
    public static let spo2Probe = CaptureLog(fileName: "spo2-candidate.txt")

    /// The skin-temperature candidate probe's file, `Documents/skin-temperature-candidate.txt`.
    ///
    /// A third file rather than a third kind of line in the second: the two probes answer different
    /// questions about different bytes, and a file is the unit a person can hand over — the SpO2 file
    /// exists to be shared without also sharing the nearest thing to a temperature, and vice versa.
    public static let skinTempProbe = CaptureLog(fileName: "skin-temperature-candidate.txt")

    /// The sleep classifier's own decisions, `Documents/sleep.txt`.
    ///
    /// **A fourth file because a night's evidence was being rotated out by a drain.** Measured
    /// 2026-10-30: `capture.txt` is capped at 64 KB and one morning drain writes hundreds of
    /// `DRAIN_BATCH` lines, so by the time a night was questioned both the `SLEEP inputs` line and the
    /// `NIGHTS check` line that would have explained it had gone — the two lines this app writes
    /// *because* a night's shape is otherwise invisible. A classifier decision is a handful of lines a
    /// day; the drain's noise is thousands. They rotate at the same rate only if they share a file.
    ///
    /// The same lines still go to `capture.txt` as well, so a capture taken for another reason is no
    /// less complete than it was; this file is the copy that survives.
    public static let sleep = CaptureLog(fileName: "sleep.txt")

    /// The accelerometer candidate probe's file, `Documents/accelerometer-candidate.txt`.
    ///
    /// The third of the three probe files, and the one the sleep classifier's own stillness depends on:
    /// `SampleStillnessMath` reads the triplet this probe dumps. See `AccelerometerCandidateProbe`.
    public static let accelerometerProbe = CaptureLog(fileName: "accelerometer-candidate.txt")

    /// Write one classifier line to both places it belongs: `capture.txt` and `sleep.txt`.
    ///
    /// One call rather than two `append`s at each site, so a line can never reach one file and not the
    /// other — the failure that would make this whole arrangement silently half-work.
    public static func sleepDecision(_ line: String) {
        shared.append(line)
        sleep.append(line)
    }

    /// ~64 KB, from `docs/TODO.md` §5.
    public static let maximumBytes = 64 * 1024

    private let queue = DispatchQueue(label: "org.whoopsy.capture-log")
    private let fileURL: URL
    private let rotatedURL: URL

    /// - Parameters:
    ///   - fileName: the file's name inside the directory.
    ///   - directory: nil uses `defaultDirectory()`. A test passes its own, so the suite never writes
    ///     into the developer's real container.
    public init(fileName: String, directory: URL? = nil) {
        let directory = directory ?? Self.defaultDirectory()
        // The directory may not exist — a scratch path on the host build does not, and a write into a
        // missing directory would fail silently for the whole run.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        rotatedURL = fileURL.appendingPathExtension("1")
    }

    /// Where the files live when no directory is passed.
    ///
    /// **The app container is the phone's answer and only the phone's.** On iOS `.documentDirectory` is
    /// the app's own sandbox, which is what makes a capture readable in Files. A host build has no
    /// container — that search path resolves to a general user folder, and a test binary writing there
    /// puts fixture lines beside whatever the person running it keeps in it. Measured on 2026-10-26:
    /// every run appended its batches to that folder and rotated the previous file out of the way. So a
    /// host build gets a scratch directory instead:
    ///
    /// 1. `WHOOPSY_CAPTURE_DIR` when set — `scripts/test.sh` points it at `tmp/build/verify/capture`,
    ///    which is the rule in `CLAUDE.md` that everything produced while testing lives under `tmp/`.
    /// 2. Otherwise the process's temporary directory, never `.documentDirectory`.
    ///
    /// The suite asserts the property that matters rather than the path: the shared log's file is not
    /// inside `.documentDirectory`.
    public static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["WHOOPSY_CAPTURE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #if os(iOS)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("whoopsy-capture", isDirectory: true)
        #endif
    }

    /// The file's current location, for a caller that wants to surface it.
    public var url: URL { fileURL }

    /// Appends one line, timestamped in UTC.
    ///
    /// Serialised on a private queue so two senders can never interleave a rotation with a write.
    /// Errors are logged rather than thrown: a capture failing to write must never take a drain with
    /// it, and the `.notice` line the caller has already emitted is the fallback record.
    public func append(_ message: String) {
        let line = "\(Date().ISO8601Format()) \(message)\n"
        queue.sync {
            do {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let size = attributes[.size] as? Int,
                   size + line.utf8.count > Self.maximumBytes {
                    try rotate()
                }
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try Data(line.utf8).write(to: fileURL, options: .atomic)
                    return
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                AppLogger.ble.error(
                    "capture log write failed for \(self.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func rotate() throws {
        if FileManager.default.fileExists(atPath: rotatedURL.path) {
            try FileManager.default.removeItem(at: rotatedURL)
        }
        try FileManager.default.moveItem(at: fileURL, to: rotatedURL)
    }
}
