import XCTest
import Foundation
@testable import Whoopsy

final class MathTests: XCTestCase {
    func testRMSSDCalculation() {
        let rrList: [Double] = [800.0, 805.0, 810.0, 795.0, 1500.0, 802.0, 808.0]
        let rmssd = HeartRateVariabilityMath.calculateRMSSD(from: rrList)

        XCTAssertGreaterThan(rmssd, 0.0)
        XCTAssertLessThan(rmssd, 50.0) // Outlier properly filtered
    }

    func testStrainAccumulator() {
        let zeroStrain = StrainAccumulatorMath.calculateStrainScore(from: 0.0)
        XCTAssertEqual(zeroStrain, 0.0)

        let moderateStrain = StrainAccumulatorMath.calculateStrainScore(from: 50_000.0)
        XCTAssertTrue(moderateStrain >= 10.0 && moderateStrain <= 20.0)

        let extremeStrain = StrainAccumulatorMath.calculateStrainScore(from: 1_000_000.0)
        XCTAssertLessThanOrEqual(extremeStrain, 21.0)
        XCTAssertGreaterThanOrEqual(extremeStrain, 20.9)
    }

    func testHRZones() {
        let zones = StrainAccumulatorMath.computeZones(maxHR: 190, restHR: 50)
        XCTAssertEqual(zones.count, 5)
        XCTAssertLessThan(zones[0].lowerBpm, zones[1].lowerBpm)
        XCTAssertEqual(zones[4].upperBpm, 190)
    }

    func testRecoveryScore() {
        // High HRV + Low RHR = Green Recovery
        let greenScore = BaselineStatisticsMath.computeRecoveryScore(
            todayHrv: 85.0,
            baselineHrvMean: 65.0,
            baselineHrvStd: 10.0,
            todayRhr: 48.0,
            baselineRhrMean: 54.0,
            baselineRhrStd: 3.0,
            sleepPerformance: 0.95
        )
        XCTAssertGreaterThanOrEqual(greenScore, 67)

        // Low HRV + Elevated RHR = Red Recovery
        let redScore = BaselineStatisticsMath.computeRecoveryScore(
            todayHrv: 35.0,
            baselineHrvMean: 65.0,
            baselineHrvStd: 10.0,
            todayRhr: 64.0,
            baselineRhrMean: 54.0,
            baselineRhrStd: 3.0,
            sleepPerformance: 0.60
        )
        XCTAssertLessThanOrEqual(redScore, 35)
    }
}
