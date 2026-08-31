import Foundation

enum SensitiveDataScanner {
    private struct Rule {
        let id: String
        let label: String
        let severity: SensitiveDataFinding.Severity
        let expression: NSRegularExpression
    }

    private static let rules: [Rule] = [
        makeRule("private-key", "私钥", .high,
             #"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"#),
        makeRule("openai-key", "API Key", .high,
             #"\bsk-[A-Za-z0-9_-]{20,}\b"#),
        makeRule("github-token", "GitHub Token", .high,
             #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
        makeRule("aws-key", "AWS Access Key", .high,
             #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#),
        makeRule("slack-token", "Slack Token", .high,
             #"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"#),
        makeRule("jwt", "JWT", .high,
             #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#),
        makeRule("password", "疑似密码字段", .medium,
             #"(?i)\b(?:password|passwd|pwd|secret)\s*[:=]\s*[^\s,;]{6,}"#),
        makeRule("bank-card", "疑似银行卡号", .medium,
             #"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#),
    ].compactMap { $0 }

    static func scan(_ text: String) -> [SensitiveDataFinding] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return rules.compactMap { rule in
            guard rule.expression.firstMatch(in: text, range: range) != nil else { return nil }
            return SensitiveDataFinding(id: rule.id, label: rule.label, severity: rule.severity)
        }
    }

    private static func makeRule(_ id: String, _ label: String,
                                 _ severity: SensitiveDataFinding.Severity,
                                 _ pattern: String) -> Rule? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return Rule(id: id, label: label, severity: severity, expression: expression)
    }
}
