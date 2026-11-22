import Foundation
public enum FeedbackReport {
    public static func redact(_ input: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var text = input.replacingOccurrences(of: home, with: "~")
        for (pattern, replacement) in [
            (#"\b7656119\d{10}\b"#, "<SteamID>"),
            (#"(?i)\b(authorization)\s*[:=]\s*(?:Bearer|Basic)\s+[^\s,;]+"#, "$1=<redacted>"),
            (#"(?i)\b(authorization|access[_-]?token|refresh[_-]?token|token|password|passwd|secret|api[_-]?key|depot[_-]?key|appticket|eticket)\b["']?\s*[:=]\s*(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;]+)"#, "$1=<redacted>"),
            (#"(?i)([?&](?:key|token|code|secret)=)[^&#\s]+"#, "$1<redacted>"),
            (#"\b[A-Fa-f0-9]{64,}\b"#, "<hex redacted>")
        ] { text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        return text
    }
    public static func make(title: String, steps: String, expected: String, actual: String, includeDiagnostics: Bool, version: String, runtime: RuntimeStatus, recentEvents: [String]) -> String {
        var text = "# " + title + "\n\n## Steps / 重现步骤\n" + steps + "\n\n## Expected / 预期结果\n" + expected + "\n\n## Actual / 实际结果\n" + actual + "\n"
        if includeDiagnostics {
            text += "\n## Environment / 环境\nMacSteamTool: \(version)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nArchitecture: arm64\nmacSteam loaded: \(!runtime.macSteamLoaded.isEmpty)\nNotProton loaded: \(!runtime.notProtonLoaded.isEmpty)\n"
            text += "\n## Recent application events / 近期应用事件\n```text\n" + recentEvents.prefix(20).joined(separator: "\n") + "\n```\n"
        }
        return redact(text)
    }
}
