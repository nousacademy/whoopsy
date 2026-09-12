import Foundation

public struct LocalExportResult: Sendable {
    public let jsonString: String
    public let csvHeartRates: String
    public let timestamp: Date

    public init(jsonString: String, csvHeartRates: String, timestamp: Date = Date()) {
        self.jsonString = jsonString
        self.csvHeartRates = csvHeartRates
        self.timestamp = timestamp
    }
}

public final class ExportLocalDataUseCase: Sendable {
    private let biometricRepository: any BiometricRepository
    private let recoveryRepository: any RecoveryRepository
    private let strainRepository: any StrainRepository
    private let sleepRepository: any SleepRepository

    public init(
        biometricRepository: any BiometricRepository,
        recoveryRepository: any RecoveryRepository,
        strainRepository: any StrainRepository,
        sleepRepository: any SleepRepository
    ) {
        self.biometricRepository = biometricRepository
        self.recoveryRepository = recoveryRepository
        self.strainRepository = strainRepository
        self.sleepRepository = sleepRepository
    }

    public func execute() async throws -> LocalExportResult {
        let now = Date()
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        
        let samples = try await biometricRepository.getSamples(from: thirtyDaysAgo, to: now)
        let recoveries = try await recoveryRepository.getRecoveryHistory(days: 30)
        let strains = try await strainRepository.getStrainHistory(days: 30)
        let sleeps = try await sleepRepository.getSleepHistory(days: 30)

        // Generate CSV of heart rate series
        var csv = "Timestamp,HeartRateBPM,RRIntervalMs,SkinTempC,SpO2\n"
        let isoFormatter = ISO8601DateFormatter()
        for s in samples {
            let rr = s.rrIntervalMs.map { String(format: "%.1f", $0) } ?? ""
            let temp = s.skinTemperatureCelsius.map { String(format: "%.2f", $0) } ?? ""
            let spo2 = s.spO2Percentage.map { String(format: "%.1f", $0) } ?? ""
            csv += "\(isoFormatter.string(from: s.timestamp)),\(s.heartRate),\(rr),\(temp),\(spo2)\n"
        }

        // Generate JSON bundle
        let jsonDict: [String: Any] = [
            "exportDate": isoFormatter.string(from: now),
            "sampleCount": samples.count,
            "recoveriesCount": recoveries.count,
            "strainsCount": strains.count,
            "sleepsCount": sleeps.count
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: .prettyPrinted)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        return LocalExportResult(jsonString: jsonString, csvHeartRates: csv, timestamp: now)
    }
}
