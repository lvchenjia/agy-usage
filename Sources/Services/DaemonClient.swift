import Foundation
import Cocoa
import Darwin

class LocalhostSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust,
           challenge.protectionSpace.host == "127.0.0.1" || challenge.protectionSpace.host == "localhost" {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

enum QuotaFetchResult {
    case enhanced([EnhancedQuotaGroup], EndpointTarget)
    case legacy([ClientModelConfig], EndpointTarget)
    case failure(String)
}

class DaemonClient {
    static let shared = DaemonClient()
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        return URLSession(configuration: config, delegate: LocalhostSessionDelegate(), delegateQueue: nil)
    }()
    
    private(set) var cachedWorkingTarget: EndpointTarget? = nil
    
    func resetWorkingTarget() {
        cachedWorkingTarget = nil
    }
    
    func isAgyProcessRunning() -> Bool {
        let targetName = ProcessInfo.processInfo.environment["AGY_TEST_TARGET_PROCESS"] ?? "agy"
        
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytesUsed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        if bytesUsed <= 0 { return false }
        
        let count = Int(bytesUsed) / MemoryLayout<pid_t>.stride
        for i in 0..<count {
            let pid = pids[i]
            if pid <= 0 { continue }
            var buffer = [CChar](repeating: 0, count: 256)
            let nameLen = proc_name(pid, &buffer, UInt32(buffer.count))
            if nameLen > 0 {
                let name = String(cString: buffer)
                if name == targetName || name.hasSuffix("/\(targetName)") {
                    return true
                }
            }
        }
        return false
    }
    
    func fetchStatus(completion: @escaping (QuotaFetchResult) -> Void) {
        if let cached = cachedWorkingTarget {
            tryFetch(targets: [cached], index: 0, isFallbackScan: false, completion: completion)
            return
        }
        scanAndFetch(completion: completion)
    }
    
    private func scanAndFetch(completion: @escaping (QuotaFetchResult) -> Void) {
        let ports = discoverCandidatePorts()
        if ports.isEmpty {
            completion(.failure("No agy daemon ports found"))
            return
        }
        var targets: [EndpointTarget] = []
        for p in ports {
            targets.append(EndpointTarget(scheme: "https", port: p))
            targets.append(EndpointTarget(scheme: "http", port: p))
        }
        tryFetch(targets: targets, index: 0, isFallbackScan: true, completion: completion)
    }
    
    private func tryFetch(targets: [EndpointTarget], index: Int, isFallbackScan: Bool, completion: @escaping (QuotaFetchResult) -> Void) {
        guard index < targets.count else {
            if !isFallbackScan {
                cachedWorkingTarget = nil
                scanAndFetch(completion: completion)
                return
            }
            cachedWorkingTarget = nil
            completion(.failure("All candidate endpoints failed or returned empty configs"))
            return
        }
        
        let target = targets[index]
        let quotaUrlString = "\(target.scheme)://127.0.0.1:\(target.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
        guard let quotaUrl = URL(string: quotaUrlString) else {
            tryFetch(targets: targets, index: index + 1, isFallbackScan: isFallbackScan, completion: completion)
            return
        }
        
        var request = URLRequest(url: quotaUrl)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let csrfToken = getCsrfToken() {
            request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        }
        request.httpBody = "{}".data(using: .utf8)
        request.timeoutInterval = 3.0
        
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let data = data, error == nil {
                let decoder = JSONDecoder()
                
                // Path 1: RetrieveUserQuotaSummary succeeded with groups
                if let summaryResp = try? decoder.decode(QuotaSummaryResponse.self, from: data),
                   let rawGroups = summaryResp.response?.groups, !rawGroups.isEmpty {
                    let enhancedGroups = self.parseEnhancedQuotaGroups(from: rawGroups)
                    self.cachedWorkingTarget = target
                    completion(.enhanced(enhancedGroups, target))
                    return
                }
                
                // Path 2: Payload is directly GetUserStatus (e.g. test mock server)
                if let statusResp = try? decoder.decode(GetUserStatusResponse.self, from: data),
                   let configs = statusResp.userStatus?.cascadeModelConfigData?.clientModelConfigs, !configs.isEmpty {
                    self.cachedWorkingTarget = target
                    completion(.legacy(configs, target))
                    return
                }
            }
            
            // Path 3: Fall back to GetUserStatus on this target
            self.fetchFallbackGetUserStatus(targets: targets, index: index, target: target, isFallbackScan: isFallbackScan, completion: completion)
        }
        task.resume()
    }
    
    private func fetchFallbackGetUserStatus(targets: [EndpointTarget], index: Int, target: EndpointTarget, isFallbackScan: Bool, completion: @escaping (QuotaFetchResult) -> Void) {
        let urlString = "\(target.scheme)://127.0.0.1:\(target.port)/exa.language_server_pb.LanguageServerService/GetUserStatus"
        guard let url = URL(string: urlString) else {
            tryFetch(targets: targets, index: index + 1, isFallbackScan: isFallbackScan, completion: completion)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let csrfToken = getCsrfToken() {
            request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        }
        request.httpBody = "{}".data(using: .utf8)
        request.timeoutInterval = 3.0
        
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if error != nil || data == nil {
                self.tryFetch(targets: targets, index: index + 1, isFallbackScan: isFallbackScan, completion: completion)
                return
            }
            
            do {
                let decoder = JSONDecoder()
                let responseObj = try decoder.decode(GetUserStatusResponse.self, from: data!)
                guard let configs = responseObj.userStatus?.cascadeModelConfigData?.clientModelConfigs, !configs.isEmpty else {
                    self.tryFetch(targets: targets, index: index + 1, isFallbackScan: isFallbackScan, completion: completion)
                    return
                }
                
                self.cachedWorkingTarget = target
                completion(.legacy(configs, target))
            } catch {
                self.tryFetch(targets: targets, index: index + 1, isFallbackScan: isFallbackScan, completion: completion)
            }
        }
        task.resume()
    }
    
    private func parseEnhancedQuotaGroups(from quotaGroups: [QuotaGroup]) -> [EnhancedQuotaGroup] {
        var result: [EnhancedQuotaGroup] = []
        for g in quotaGroups {
            let rawTitle = g.displayName ?? "Models"
            let title: String
            if rawTitle.localizedCaseInsensitiveContains("Gemini") {
                title = "Gemini"
            } else if rawTitle.localizedCaseInsensitiveContains("Claude") || rawTitle.localizedCaseInsensitiveContains("GPT") {
                title = "Claude & GPT"
            } else {
                title = rawTitle
            }
            
            var fiveHourBucket: QuotaBucket? = nil
            var weeklyBucket: QuotaBucket? = nil
            
            if let buckets = g.buckets {
                for b in buckets {
                    let win = b.window?.lowercased() ?? ""
                    let bid = b.bucketId?.lowercased() ?? ""
                    if win == "5h" || bid.contains("5h") {
                        fiveHourBucket = b
                    } else if win == "weekly" || bid.contains("weekly") {
                        weeklyBucket = b
                    }
                }
            }
            
            let fiveHourFrac = fiveHourBucket?.remainingFraction ?? 1.0
            let fiveHourReset = fiveHourBucket?.resetTime
            let weeklyFrac = weeklyBucket?.remainingFraction
            let weeklyReset = weeklyBucket?.resetTime
            
            result.append(EnhancedQuotaGroup(
                title: title,
                fiveHourFraction: fiveHourFrac,
                fiveHourReset: fiveHourReset,
                weeklyFraction: weeklyFrac,
                weeklyReset: weeklyReset
            ))
        }
        return result
    }
    
    func discoverCandidatePorts() -> [Int] {
        if let testPortStr = ProcessInfo.processInfo.environment["AGY_TEST_PORT"], let testPort = Int(testPortStr) {
            return [testPort]
        }
        
        let process = Process()
        process.launchPath = "/usr/sbin/lsof"
        process.arguments = ["-c", "agy", "-a", "-iTCP", "-sTCP:LISTEN", "-P", "-n"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            
            if let output = String(data: data, encoding: .utf8) {
                var ports: [Int] = []
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    if line.contains("LISTEN") {
                        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        if let nameCol = parts.last(where: { $0.contains(":") }) {
                            let portStr = nameCol.components(separatedBy: ":").last ?? ""
                            if let port = Int(portStr) {
                                ports.append(port)
                            }
                        }
                    }
                }
                return ports
            }
        } catch {
            return []
        }
        
        return []
    }
    
    func getCsrfToken() -> String? {
        if let testToken = ProcessInfo.processInfo.environment["AGY_TEST_TOKEN"] {
            return testToken
        }
        
        // 1. Try file
        let tokenPath = "/tmp/agy_csrf_token"
        if let content = try? String(contentsOfFile: tokenPath, encoding: .utf8) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        
        // 2. Try ps
        let process = Process()
        process.launchPath = "/bin/ps"
        process.arguments = ["-eo", "args"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            
            if let output = String(data: data, encoding: .utf8) {
                let pattern = "--csrf_token=([a-zA-Z0-9-]+)"
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let nsString = output as NSString
                    let results = regex.matches(in: output, range: NSRange(location: 0, length: nsString.length))
                    if let firstMatch = results.first {
                        return nsString.substring(with: firstMatch.range(at: 1))
                    }
                }
            }
        } catch {
            return nil
        }
        
        return nil
    }
}
