import Foundation
import SQLite3

class TokenStatsManager {
    static let shared = TokenStatsManager()
    
    private let homeDir = FileManager.default.homeDirectoryForCurrentUser
    private var brainDir: URL {
        homeDir.appendingPathComponent(".gemini/antigravity-cli/brain")
    }
    private var convDir: URL {
        homeDir.appendingPathComponent(".gemini/antigravity-cli/conversations")
    }
    
    private let lock = NSLock()
    
    // Level 1: Global in-memory cache of all combined records
    private var memoryCacheRecords: [TokenRecord] = []
    private var lastScanTime: Date? = nil
    
    // Level 2: Per-session incremental cache (mtime + fileSize -> records)
    private var sessionCache: [String: CachedSessionRecords] = [:]
    
    // Level 3: SQLite model mapping cache (convId -> [idx: modelName])
    private var modelMapCache: [String: [Int: String]] = [:]
    
    private let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    
    private let isoDateFractionFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    
    var currentRecords: [TokenRecord] {
        lock.lock()
        defer { lock.unlock() }
        return memoryCacheRecords
    }
    
    func parseDate(_ str: String?) -> Date? {
        guard let s = str, !s.isEmpty else { return nil }
        return isoDateFormatter.date(from: s) ?? isoDateFractionFormatter.date(from: s)
    }
    
    func scanAllRecords(forceRefresh: Bool = false) -> [TokenRecord] {
        lock.lock()
        defer { lock.unlock() }
        
        // Level 1: Memory cache short-circuit for rapid UI queries
        if !forceRefresh, !memoryCacheRecords.isEmpty, let last = lastScanTime, Date().timeIntervalSince(last) < 15.0 {
            return memoryCacheRecords
        }
        
        var records: [TokenRecord] = []
        let fileManager = FileManager.default
        guard let dbFiles = try? fileManager.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil) else {
            return memoryCacheRecords
        }
        
        for dbURL in dbFiles where dbURL.pathExtension == "db" {
            let convId = dbURL.deletingPathExtension().lastPathComponent
            let transcriptURL = brainDir.appendingPathComponent(convId).appendingPathComponent(".system_generated/logs/transcript.jsonl")
            
            // Check file attributes for incremental cache
            guard let attrs = try? fileManager.attributesOfItem(atPath: transcriptURL.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.int64Value else {
                continue
            }
            
            // Level 2 cache hit: file has not been modified since last parse
            if let cached = sessionCache[convId], cached.modificationDate == mtime && cached.fileSize == size {
                records.append(contentsOf: cached.records)
                continue
            }
            
            // Level 2 cache miss: parse transcript.jsonl
            guard let fileHandle = try? FileHandle(forReadingFrom: transcriptURL) else { continue }
            defer { try? fileHandle.close() }
            
            let data = fileHandle.readDataToEndOfFile()
            guard let content = String(data: data, encoding: .utf8) else { continue }
            
            let modelMap = getModelMap(for: convId, dbURL: dbURL)
            var sessionRecords: [TokenRecord] = []
            var genIdx = 0
            
            content.enumerateLines { [weak self] line, _ in
                guard line.contains("\"PLANNER_RESPONSE\"") else { return }
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      (json["type"] as? String) == "PLANNER_RESPONSE" else { return }
                
                let input = (json["input_tokens"] as? NSNumber)?.int64Value
                let cache = (json["cache_read_tokens"] as? NSNumber)?.int64Value ?? 0
                let output = (json["output_tokens"] as? NSNumber)?.int64Value ?? 0
                let createdAtStr = json["created_at"] as? String
                let date = self?.parseDate(createdAtStr)
                
                if let input = input {
                    let modelName = modelMap[genIdx] ?? (modelMap.values.first ?? "Gemini 3.8 Flash (Medium)")
                    sessionRecords.append(TokenRecord(
                        modelName: modelName,
                        inputTokens: input,
                        cacheReadTokens: cache,
                        outputTokens: output,
                        timestamp: date
                    ))
                }
                genIdx += 1
            }
            
            // Store in per-session incremental cache
            sessionCache[convId] = CachedSessionRecords(modificationDate: mtime, fileSize: size, records: sessionRecords)
            records.append(contentsOf: sessionRecords)
        }
        
        self.memoryCacheRecords = records
        self.lastScanTime = Date()
        return records
    }
    
    private static let knownPatterns: [(Data, String)] = [
        ("Claude Sonnet 4.6 (Thinking)".data(using: .utf8)!, "Claude Sonnet 4.6 (Thinking)"),
        ("Claude Sonnet 4.6".data(using: .utf8)!, "Claude Sonnet 4.6"),
        ("Claude Opus 4.6 (Thinking)".data(using: .utf8)!, "Claude Opus 4.6 (Thinking)"),
        ("Claude Opus 4.6".data(using: .utf8)!, "Claude Opus 4.6"),
        ("Gemini 3.8 Flash (High)".data(using: .utf8)!, "Gemini 3.8 Flash (High)"),
        ("Gemini 3.8 Flash (Medium)".data(using: .utf8)!, "Gemini 3.8 Flash (Medium)"),
        ("Gemini 3.8 Flash (Low)".data(using: .utf8)!, "Gemini 3.8 Flash (Low)"),
        ("Gemini 3.5 Flash (High)".data(using: .utf8)!, "Gemini 3.5 Flash (High)"),
        ("Gemini 3.5 Flash".data(using: .utf8)!, "Gemini 3.5 Flash"),
        ("GPT-OSS 120B (Medium)".data(using: .utf8)!, "GPT-OSS 120B (Medium)"),
        ("GPT-OSS 120B".data(using: .utf8)!, "GPT-OSS 120B"),
        ("Gemini 4 Argon".data(using: .utf8)!, "Gemini 4 Argon")
    ]
    
    private func getModelMap(for convId: String, dbURL: URL) -> [Int: String] {
        if let cached = modelMapCache[convId] {
            return cached
        }
        let map = loadModelMap(from: dbURL)
        modelMapCache[convId] = map
        return map
    }
    
    private func loadModelMap(from dbURL: URL) -> [Int: String] {
        var map: [Int: String] = [:]
        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
            var stmt: OpaquePointer?
            let query = "SELECT idx, data FROM gen_metadata ORDER BY idx"
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let idx = Int(sqlite3_column_int(stmt, 0))
                    if let blobPtr = sqlite3_column_blob(stmt, 1) {
                        let bytes = Int(sqlite3_column_bytes(stmt, 1))
                        let d = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: blobPtr), count: bytes, deallocator: .none)
                        map[idx] = extractModelName(from: d)
                    }
                }
                sqlite3_finalize(stmt)
            }
            sqlite3_close(db)
        }
        return map
    }
    
    private func extractModelName(from data: Data) -> String {
        for (patternData, name) in TokenStatsManager.knownPatterns {
            if data.range(of: patternData) != nil {
                return name
            }
        }
        return "Gemini 3.8 Flash (Medium)"
    }
}
