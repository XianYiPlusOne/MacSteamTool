import Foundation

/// Text KeyValues parser. Retains duplicate keys and never treats comment text as data.
public struct VDF: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: String?
        public var children: VDF?
    }
    public var entries: [Entry] = []
    public init() {}
    /// Bounded Steam binary KeyValues reader; reads definitions, never player state.
    public static func binary(_ data: Data) throws -> VDF {
        guard data.count <= 16 * 1024 * 1024 else { throw AppFailure("Binary VDF exceeds 16 MiB") }
        let bytes = [UInt8](data); var offset = 0, count = 0
        func number(_ size: Int) throws -> UInt64 {
            guard offset + size <= bytes.count else { throw AppFailure("Truncated binary VDF") }
            defer { offset += size }
            return (0..<size).reduce(0) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
        }
        func string() throws -> String {
            let start = offset
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            guard offset < bytes.count, offset - start <= 1_048_576, let value = String(bytes: bytes[start..<offset], encoding: .utf8) else { throw AppFailure("Invalid binary VDF string") }
            offset += 1; return value
        }
        func section(_ depth: Int) throws -> VDF {
            guard depth <= 64 else { throw AppFailure("Binary VDF nesting limit") }
            var result = VDF()
            while offset < bytes.count {
                let type = try number(1)
                if type == 8 { return result }
                count += 1; guard count <= 100_000 else { throw AppFailure("Binary VDF node limit") }
                let key = try string()
                switch type {
                case 0: result.entries.append(Entry(key: key, children: try section(depth + 1)))
                case 1: result.entries.append(Entry(key: key, value: try string()))
                case 2: result.entries.append(Entry(key: key, value: String(Int32(bitPattern: UInt32(try number(4))))))
                case 3: result.entries.append(Entry(key: key, value: String(Float(bitPattern: UInt32(try number(4))))))
                case 7: result.entries.append(Entry(key: key, value: String(try number(8))))
                case 10: result.entries.append(Entry(key: key, value: String(Int64(bitPattern: try number(8)))))
                default: throw AppFailure("Unsupported binary VDF type: \(type)")
                }
            }
            guard depth == 0 else { throw AppFailure("Unterminated binary VDF section") }
            return result
        }
        let result = try section(0)
        guard offset == bytes.count else { throw AppFailure("Trailing binary VDF data") }
        return result
    }
    public func string(_ key: String) -> String? { entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value }
    public func object(_ key: String) -> VDF? { entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.children }
    public mutating func set(_ key: String, value: String) {
        if let i = entries.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) { entries[i].value = value; entries[i].children = nil }
        else { entries.append(Entry(key: key, value: value)) }
    }
    public mutating func set(_ key: String, object: VDF) {
        if let i = entries.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) { entries[i] = Entry(key: key, children: object) }
        else { entries.append(Entry(key: key, children: object)) }
    }
    public func serialized(indent: Int = 0) -> String {
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\"" }
        let pad = String(repeating: "\t", count: indent)
        return entries.map { e in
            if let c = e.children { return "\(pad)\(quote(e.key))\n\(pad){\n\(c.serialized(indent: indent + 1))\(pad)}\n" }
            return "\(pad)\(quote(e.key))\t\t\(quote(e.value ?? ""))\n"
        }.joined()
    }
    public static func parse(_ text: String) throws -> VDF {
        enum Token { case word(String), open, close }
        let chars = Array(text); var cursor = 0; var tokens: [Token] = []
        while cursor < chars.count {
            let c = chars[cursor]
            if c.isWhitespace || c == "\u{feff}" { cursor += 1; continue }
            if c == "/", cursor + 1 < chars.count, chars[cursor + 1] == "/" {
                while cursor < chars.count && chars[cursor] != "\n" { cursor += 1 }; continue
            }
            if c == "{" { tokens.append(.open); cursor += 1; continue }
            if c == "}" { tokens.append(.close); cursor += 1; continue }
            var word = ""
            if c == "\"" {
                cursor += 1; var closed = false
                while cursor < chars.count {
                    let x = chars[cursor]; cursor += 1
                    if x == "\"" { closed = true; break }
                    if x == "\\", cursor < chars.count {
                        let next = chars[cursor]; cursor += 1
                        switch next { case "n": word += "\n"; case "t": word += "\t"; case "\\", "\"": word.append(next); default: word.append("\\"); word.append(next) }
                    } else { word.append(x) }
                }
                guard closed else { throw AppFailure("VDF 字符串未闭合 / Unterminated VDF string") }
            } else {
                while cursor < chars.count && !chars[cursor].isWhitespace && chars[cursor] != "{" && chars[cursor] != "}" { word.append(chars[cursor]); cursor += 1 }
            }
            tokens.append(.word(word))
        }
        var i = 0
        func object(_ nested: Bool, depth: Int) throws -> VDF {
            guard depth < 64 else { throw AppFailure("VDF 嵌套过深 / VDF nesting limit exceeded") }
            var result = VDF()
            while i < tokens.count {
                if case .close = tokens[i] {
                    guard nested else { throw AppFailure("VDF 包含多余的右括号 / Unexpected VDF closing brace") }; i += 1; return result
                }
                guard case .word(let key) = tokens[i] else { throw AppFailure("VDF 缺少键名 / Missing VDF key") }; i += 1
                guard i < tokens.count else { throw AppFailure("VDF 缺少值 / Missing VDF value") }
                switch tokens[i] {
                case .word(let value): result.entries.append(Entry(key: key, value: value)); i += 1
                case .open: i += 1; result.entries.append(Entry(key: key, children: try object(true, depth: depth + 1)))
                case .close: throw AppFailure("VDF 缺少值 / Missing VDF value")
                }
            }
            guard !nested else { throw AppFailure("VDF 对象未闭合 / Unterminated VDF object") }; return result
        }
        return try object(false, depth: 0)
    }
}
