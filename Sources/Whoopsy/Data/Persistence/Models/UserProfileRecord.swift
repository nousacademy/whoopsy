import Foundation
import GRDB

public struct UserProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "user_profiles"

    public var id: String
    public var maxHeartRate: Int
    public var restingHeartRate: Int

    public init(id: String = "primary", maxHeartRate: Int, restingHeartRate: Int) {
        self.id = id
        self.maxHeartRate = maxHeartRate
        self.restingHeartRate = restingHeartRate
    }
}