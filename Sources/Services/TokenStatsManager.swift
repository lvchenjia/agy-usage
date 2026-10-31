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
    
    // Level 3: SQLite session metadata cache (convId -> SessionMetadata)
    private struct SessionMetadata {
        let modelMap: [Int: String]
        let stepDurations: [Int: Double]
    }
    private var sessionMetaCache: [String: SessionMetadata] = [:]
    
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
            
            let meta = getSessionMetadata(for: convId, dbURL: dbURL)
            let modelMap = meta.modelMap
            let stepDurations = meta.stepDurations
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
                let stepIndex = (json["step_index"] as? NSNumber)?.intValue
                let duration = stepIndex.flatMap { stepDurations[$0] } ?? 0.0
                
                if let input = input {
                    let modelName = modelMap[genIdx] ?? (modelMap.values.first ?? "Gemini 3.8 Flash (Medium)")
                    sessionRecords.append(TokenRecord(
                        modelName: modelName,
                        inputTokens: input,
                        cacheReadTokens: cache,
                        outputTokens: output,
                        timestamp: date,
                        durationSeconds: duration
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
    
    private func getSessionMetadata(for convId: String, dbURL: URL) -> SessionMetadata {
        if let cached = sessionMetaCache[convId] {
            return cached
        }
        let meta = loadSessionMetadata(from: dbURL)
        sessionMetaCache[convId] = meta
        return meta
    }
    
    private func loadSessionMetadata(from dbURL: URL) -> SessionMetadata {
        var modelMap: [Int: String] = [:]
        var stepDurations: [Int: Double] = [:]
        
        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
            // 1. Model Mapping
            var stmtModel: OpaquePointer?
            let queryModel = "SELECT idx, data FROM gen_metadata ORDER BY idx"
            if sqlite3_prepare_v2(db, queryModel, -1, &stmtModel, nil) == SQLITE_OK {
                while sqlite3_step(stmtModel) == SQLITE_ROW {
                    let idx = Int(sqlite3_column_int(stmtModel, 0))
                    if let blobPtr = sqlite3_column_blob(stmtModel, 1) {
                        let bytes = Int(sqlite3_column_bytes(stmtModel, 1))
                        let d = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: blobPtr), count: bytes, deallocator: .none)
                        modelMap[idx] = extractModelName(from: d)
                    }
                }
                sqlite3_finalize(stmtModel)
            }
            
            // 2. Step Durations
            var stmtSteps: OpaquePointer?
            let querySteps = "SELECT idx, metadata FROM steps WHERE step_type = 15 ORDER BY idx"
            if sqlite3_prepare_v2(db, querySteps, -1, &stmtSteps, nil) == SQLITE_OK {
                while sqlite3_step(stmtSteps) == SQLITE_ROW {
                    let idx = Int(sqlite3_column_int(stmtSteps, 0))
                    if let blobPtr = sqlite3_column_blob(stmtSteps, 1) {
                        let bytes = Int(sqlite3_column_bytes(stmtSteps, 1))
                        let d = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: blobPtr), count: bytes, deallocator: .none)
                        let dur = TokenStatsManager.parseStepDuration(from: d)
                        if dur > 0 {
                            stepDurations[idx] = dur
                        }
                    }
                }
                sqlite3_finalize(stmtSteps)
            }
            
            sqlite3_close(db)
        }
        return SessionMetadata(modelMap: modelMap, stepDurations: stepDurations)
    }
    
    private static func decodeVarint(_ bytes: [UInt8], from index: inout Int) -> UInt64 {
        var val: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let b = bytes[index]
            index += 1
            val |= UInt64(b & 0x7F) << shift
            shift += 7
            if (b & 0x80) == 0 { break }
        }
        return val
    }
    
    private static func decodeTimestamp(_ bytes: [UInt8]) -> Double? {
        var idx = 0
        var seconds: Double? = nil
        var nanos: Double = 0.0
        while idx < bytes.count {
            let tagByte = bytes[idx]
            idx += 1
            let fieldNum = tagByte >> 3
            let val = decodeVarint(bytes, from: &idx)
            if fieldNum == 1 {
                seconds = Double(val)
            } else if fieldNum == 2 {
                nanos = Double(val)
            }
        }
        if let s = seconds {
            return s + (nanos / 1_000_000_000.0)
        }
        return nil
    }
    
    private static func parseStepDuration(from data: Data) -> Double {
        let bytes = [UInt8](data)
        var idx = 0
        var tCreate: Double? = nil
        var tFinish: Double? = nil
        
        while idx < bytes.count {
            let key = decodeVarint(bytes, from: &idx)
            let fieldNum = key >> 3
            let wireType = key & 7
            if wireType == 0 {
                _ = decodeVarint(bytes, from: &idx)
            } else if wireType == 2 {
                let length = Int(decodeVarint(bytes, from: &idx))
                let end = min(idx + length, bytes.count)
                let sub = Array(bytes[idx..<end])
                idx = end
                if fieldNum == 1 {
                    tCreate = decodeTimestamp(sub)
                } else if fieldNum == 7 {
                    tFinish = decodeTimestamp(sub)
                }
            } else {
                break
            }
        }
        
        if let tc = tCreate, let tf = tFinish, tf >= tc {
            return tf - tc
        }
        return 0.0
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
