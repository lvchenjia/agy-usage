import Foundation

func formatKMB(_ n: Int64) -> String {
    let absN = abs(n)
    let sign = n < 0 ? "-" : ""
    if absN >= 1_000_000_000 {
        let val = Double(absN) / 1_000_000_000.0
        return String(format: "%@%.2fB", sign, val)
    } else if absN >= 1_000_000 {
        let val = Double(absN) / 1_000_000.0
        if val >= 100 {
            return String(format: "%@%.0fM", sign, val)
        } else if val >= 10 {
            return String(format: "%@%.1fM", sign, val)
        } else {
            return String(format: "%@%.2fM", sign, val)
        }
    } else if absN >= 1_000 {
        let val = Double(absN) / 1_000.0
        if val >= 100 {
            return String(format: "%@%.0fK", sign, val)
        } else {
            return String(format: "%@%.1fK", sign, val)
        }
    } else {
        return "\(n)"
    }
}

func formatTokenSpeed(_ speed: Double?) -> (value: String, unit: String?) {
    guard let speed = speed, speed > 0 else { return ("--", nil) }
    if speed >= 100 {
        return (String(format: "%.0f", speed), "tok/s")
    } else {
        return (String(format: "%.1f", speed), "tok/s")
    }
}

func formatResetTime(_ dateString: String?) -> String {
    guard let dateString = dateString else { return "No reset time" }
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: dateString) else { return "Reset time unknown" }
    
    let now = Date()
    let timeInterval = date.timeIntervalSince(now)
    
    if timeInterval <= 0 {
        return "Quota reset"
    }
    
    let totalMinutes = Int(timeInterval) / 60
    let totalHours = totalMinutes / 60
    let days = totalHours / 24
    let hours = totalHours % 24
    let minutes = totalMinutes % 60
    
    if days > 0 {
        return "Resets in \(days)d \(hours)h"
    } else if hours > 0 {
        return "Resets in \(hours)h \(minutes)m"
    } else {
        return "Resets in \(minutes)m"
    }
}
