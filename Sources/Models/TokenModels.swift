import Foundation

struct TokenRecord {
    let modelName: String
    let inputTokens: Int64
    let cacheReadTokens: Int64
    let outputTokens: Int64
    let timestamp: Date?
    
    var totalTokens: Int64 {
        return inputTokens + cacheReadTokens + outputTokens
    }
}

struct ModelAggregatedStats {
    let modelName: String
    var callCount: Int = 0
    var inputTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var outputTokens: Int64 = 0
    
    var totalTokens: Int64 {
        return inputTokens + cacheReadTokens + outputTokens
    }
    
    var cacheRatio: Double {
        let promptTokens = inputTokens + cacheReadTokens
        guard promptTokens > 0 else { return 0.0 }
        return Double(cacheReadTokens) / Double(promptTokens) * 100.0
    }
}

enum TimeWindow: Int, CaseIterable {
    case fiveHours = 0
    case today = 1
    case sevenDays = 2
    case thirtyDays = 3
    case allTime = 4
    
    var title: String {
        switch self {
        case .fiveHours: return "5h"
        case .today: return "24h"
        case .sevenDays: return "7d"
        case .thirtyDays: return "30d"
        case .allTime: return "All"
        }
    }
    
    var maxSeconds: TimeInterval? {
        switch self {
        case .fiveHours: return 5 * 3600
        case .today: return 24 * 3600
        case .sevenDays: return 7 * 86400
        case .thirtyDays: return 30 * 86400
        case .allTime: return nil
        }
    }
}

struct CachedSessionRecords {
    let modificationDate: Date
    let fileSize: Int64
    let records: [TokenRecord]
}
