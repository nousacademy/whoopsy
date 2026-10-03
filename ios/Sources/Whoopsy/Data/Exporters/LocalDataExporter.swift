import Foundation

/// File export manager for writing biometric backups to device filesystem or sharing via UIActivityViewController.
public final class LocalDataExporter: Sendable {
    public init() {}

    public func exportToFile(filename: String, content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileUrl = tempDir.appendingPathComponent(filename)
        try content.write(to: fileUrl, atomically: true, encoding: .utf8)
        return fileUrl
    }
}
