import Foundation

// MARK: - Legacy & UserStatus Models

struct UserAccountInfo: Codable {
    let name: String?
    let email: String?
    let planName: String?
    let tierName: String?
    let profilePictureUrl: String?
}

struct GetUserStatusResponse: Codable {
    let userStatus: UserStatus?
}

struct UserStatus: Codable {
    let name: String?
    let email: String?
    let planStatus: PlanStatus?
    let userTier: UserTier?
    let profilePictureUrl: String?
    let cascadeModelConfigData: CascadeModelConfigData?
}

struct PlanStatus: Codable {
    let planInfo: PlanInfo?
}

struct PlanInfo: Codable {
    let planName: String?
}

struct UserTier: Codable {
    let id: String?
    let name: String?
    let description: String?
}

struct CascadeModelConfigData: Codable {
    let clientModelConfigs: [ClientModelConfig]?
}

struct ClientModelConfig: Codable {
    let label: String
    let quotaInfo: QuotaInfo?
}

struct QuotaInfo: Codable {
    let remainingFraction: Double?
    let resetTime: String?
}

struct GroupedQuota {
    let name: String
    let fraction: Double
    let resetTime: String?
}

struct EndpointTarget: Equatable {
    let scheme: String
    let port: Int
}

// MARK: - RetrieveUserQuotaSummary Enhanced Models

struct QuotaSummaryResponse: Codable {
    let response: QuotaSummaryData?
}

struct QuotaSummaryData: Codable {
    let groups: [QuotaGroup]?
}

struct QuotaGroup: Codable {
    let displayName: String?
    let description: String?
    let buckets: [QuotaBucket]?
}

struct QuotaBucket: Codable {
    let bucketId: String?
    let displayName: String?
    let description: String?
    let window: String?
    let remainingFraction: Double?
    let resetTime: String?
}

struct EnhancedQuotaGroup {
    let title: String
    let fiveHourFraction: Double
    let fiveHourReset: String?
    let weeklyFraction: Double?
    let weeklyReset: String?
}
