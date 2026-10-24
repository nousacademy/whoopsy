import Foundation
import Whoopsy

/// The algorithm on the wire — the app's statement about the row, carried to the database.
enum StrainWireMapperTests {
    static func run() async throws {
        let day = StrainTests.day

        let row = StrainSyncRow(
            date: day, strainScore: 9.3, kilojoules: 1_200,
            averageHeartRate: 64, maxHeartRate: 158, hasMeasurement: true,
            source: StrainScore.deviceSource, algorithm: StrainAlgorithm.hrMotionV2.rawValue)

        let dto = StrainWireMapper.dto(for: row)
        assertTest(
            dto.algorithm == "hr-motion-v2",
            "The version reaches the wire, got \(dto.algorithm ?? "nil")")

        let round = try StrainWireMapper.row(for: dto)
        assertTest(
            round == row,
            "…and a DTO round-trips to an identical row, algorithm included")

        // A row from a client older than the field.
        let old = StrainSyncRow(
            date: day, strainScore: 9.3, kilojoules: 1_200,
            averageHeartRate: 64, maxHeartRate: 158, hasMeasurement: true,
            source: nil, algorithm: nil)
        let oldDTO = StrainWireMapper.dto(for: old)
        assertTest(
            oldDTO.algorithm == nil,
            "A row with no algorithm sends `null` rather than a guessed version")
        assertTest(
            StrainWireMapper.isSendable(old),
            "…and is still a sendable row, because the field is nullable on the contract")

        // The one value the schema refuses: an empty string is neither a version nor a `null`.
        let empty = StrainSyncRow(
            date: day, strainScore: 9.3, kilojoules: 1_200,
            averageHeartRate: 64, maxHeartRate: 158, hasMeasurement: true,
            source: nil, algorithm: "")
        assertTest(
            !StrainWireMapper.isSendable(empty),
            "An empty algorithm is refused rather than sent as a body the server would reject")

        // The entity conversion is the one place that could silently drop provenance.
        assertTest(
            round.score.algorithm == .hrMotionV2,
            "A synced row's entity carries the algorithm through")
        let importedRow = StrainSyncRow(
            date: day, strainScore: 11.0, kilojoules: 1_500,
            averageHeartRate: 66, maxHeartRate: 170, hasMeasurement: true,
            source: StrainScore.importSource, algorithm: StrainAlgorithm.whoopExport.rawValue)
        assertTest(
            importedRow.score.source == StrainScore.importSource
                && importedRow.score.isDeviceScored == false,
            "A cloud-read WHOOP row arrives with its provenance and is not repairable")
    }
}
