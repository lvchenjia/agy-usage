import Foundation

struct RemoteControlStatus {
    let isRunning: Bool
    let pid: Int?
    let rawOutput: String?
}

enum RemoteControlActionState {
    case idle
    case starting
    case stopping
}

class RemoteControlService {
    static let shared = RemoteControlService()
    
    private(set) var currentStatus: RemoteControlStatus = RemoteControlStatus(isRunning: false, pid: nil, rawOutput: nil)
    private(set) var actionState: RemoteControlActionState = .idle
    private var isChecking = false
    
    var isBusy: Bool {
        return actionState != .idle
    }
    
    func findAgyBinaryPath() -> String? {
        if let envPath = ProcessInfo.processInfo.environment["AGY_CLI_PATH"],
           FileManager.default.isExecutableFile(atPath: envPath) {
            return envPath
        }
        
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(homeDir)/.local/bin/agy",
            "/usr/local/bin/agy",
            "/opt/homebrew/bin/agy"
        ]
        
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    func checkStatus(completion: @escaping (RemoteControlStatus) -> Void) {
        if let mockRunning = ProcessInfo.processInfo.environment["AGY_TEST_RC_RUNNING"] {
            let isRunning = (mockRunning == "1" || mockRunning.lowercased() == "true")
            let status = RemoteControlStatus(isRunning: isRunning, pid: isRunning ? 55223 : nil, rawOutput: "mock")
            self.currentStatus = status
            DispatchQueue.main.async {
                completion(status)
            }
            return
        }
        
        guard let agyPath = findAgyBinaryPath() else {
            let status = RemoteControlStatus(isRunning: false, pid: nil, rawOutput: "agy binary not found")
            self.currentStatus = status
            DispatchQueue.main.async {
                completion(status)
            }
            return
        }
        
        guard !isChecking else {
            completion(self.currentStatus)
            return
        }
        isChecking = true
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            defer { self.isChecking = false }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: agyPath)
            process.arguments = ["remote-control", "status"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                
                let output = String(data: data, encoding: .utf8) ?? ""
                let isRunning = output.localizedCaseInsensitiveContains("Daemon state = running")
                
                var pid: Int? = nil
                if let pidRange = output.range(of: "Daemon pid = (\\d+)", options: .regularExpression) {
                    let pidSub = output[pidRange]
                    let digits = pidSub.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                    pid = Int(digits)
                }
                
                let status = RemoteControlStatus(isRunning: isRunning, pid: pid, rawOutput: output)
                self.currentStatus = status
                DispatchQueue.main.async {
                    completion(status)
                }
            } catch {
                let status = RemoteControlStatus(isRunning: false, pid: nil, rawOutput: error.localizedDescription)
                self.currentStatus = status
                DispatchQueue.main.async {
                    completion(status)
                }
            }
        }
    }
    
    func startRemoteControl(completion: @escaping (Bool, String?) -> Void) {
        guard actionState == .idle else {
            completion(false, "Operation already in progress")
            return
        }
        guard let agyPath = findAgyBinaryPath() else {
            completion(false, "agy binary not found")
            return
        }
        
        actionState = .starting
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: agyPath)
            process.arguments = ["remote-control", "start"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                // Immediately check status to update pid & running state
                self.checkStatus { status in
                    self.actionState = .idle
                    let success = status.isRunning
                    completion(success, output)
                }
            } catch {
                self.actionState = .idle
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }
    
    func stopRemoteControl(completion: @escaping (Bool, String?) -> Void) {
        guard actionState == .idle else {
            completion(false, "Operation already in progress")
            return
        }
        guard let agyPath = findAgyBinaryPath() else {
            completion(false, "agy binary not found")
            return
        }
        
        actionState = .stopping
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: agyPath)
            process.arguments = ["remote-control", "stop"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                // Immediately check status to update pid & running state
                self.checkStatus { status in
                    self.actionState = .idle
                    let success = !status.isRunning
                    completion(success, output)
                }
            } catch {
                self.actionState = .idle
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }
}
