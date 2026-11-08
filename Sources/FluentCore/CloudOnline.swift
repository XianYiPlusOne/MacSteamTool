import Foundation

/// Configuration validation only; never opens a connection or enables redirection.
public enum CloudOnline {
    public static func credentialValues(_ fields: [String: String], provider: CloudProvider) throws -> [String: Any] {
        guard ![.local, .folder].contains(provider), fields.values.allSatisfy({ !$0.contains("\0") }) else {
            throw AppFailure("服务商或凭证格式无效 / Invalid provider or credential format")
        }
        var result: [String: Any] = fields
        if let ca = fields["ca_cert_path"], !ca.isEmpty {
            guard ca.hasPrefix("/"), !ca.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AppFailure("CA 证书需要绝对文件路径 / CA certificate requires an absolute file path") }
        }
        for key in ["allow_insecure_http", "allow_insecure_tls", "sign_payload"] {
            if let value = fields[key] {
                guard ["true", "false"].contains(value) else { throw AppFailure("无效的开关值 / Invalid boolean setting") }
                result[key] = value == "true"
            }
        }
        if let expiry = fields["expires_at"], !expiry.isEmpty {
            guard let seconds = Int64(expiry), seconds > 0 else { throw AppFailure("凭证有效期无效 / Invalid credential expiry") }
            result["expires_at"] = seconds
        }
        if let timeout = fields["timeout_sec"], !timeout.isEmpty {
            guard let seconds = Int(timeout), (0...300).contains(seconds) else { throw AppFailure("超时应为 0–300 秒 / Timeout must be 0–300 seconds") }
            result["timeout_sec"] = seconds
        }
        let prefix = (fields["key_prefix"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !prefix.contains("\\"), !prefix.contains("%"),
              prefix.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              !prefix.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AppFailure("远端子目录不能包含路径跳转或控制字符 / Invalid remote subfolder")
        }
        result["key_prefix"] = prefix
        if provider == .webdav {
            try validateURL(fields["url"] ?? "", allowHTTP: fields["allow_insecure_http"] == "true", endpointOnly: false)
            let auth = fields["auth"] ?? ((fields["bearer_token"] ?? "").isEmpty ? "basic" : "bearer")
            guard ["basic", "digest", "auto", "ntlm", "negotiate", "bearer", "none"].contains(auth) else { throw AppFailure("认证方式无效 / Invalid authentication method") }
            if auth == "bearer" {
                let token = fields["bearer_token"] ?? ""
                guard !token.isEmpty, !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AppFailure("请输入有效的 Bearer token / Enter a valid bearer token") }
            } else if auth != "none" {
                guard !(fields["username"] ?? "").isEmpty, !(fields["password"] ?? "").isEmpty else { throw AppFailure("用户名和密码不能为空 / Username and password are required") }
            }
            result["auth"] = auth
        } else if [.s3, .r2].contains(provider) {
            guard ["access_key_id", "secret_access_key", "bucket"].allSatisfy({ !(fields[$0] ?? "").isEmpty }) else { throw AppFailure("Access Key、Secret Key 和 Bucket 不能为空 / Access key, secret key and bucket are required") }
            let bucket = fields["bucket"] ?? ""
            guard !bucket.contains("/"), !bucket.contains("\\"), !bucket.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), bucket != ".", bucket != ".." else { throw AppFailure("Bucket 名称无效 / Invalid bucket name") }
            if provider == .s3 && (fields["endpoint"] ?? "").isEmpty { throw AppFailure("S3 需要完整 Endpoint 地址 / S3 requires a complete endpoint URL") }
            if let endpoint = fields["endpoint"], !endpoint.isEmpty {
                try validateURL(endpoint, allowHTTP: fields["allow_insecure_http"] == "true", endpointOnly: true)
            }
            if provider == .r2 {
                let account = fields["account_id"] ?? ""
                guard account.utf8.count == 32, account.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw AppFailure("R2 Account ID 应为 32 位十六进制字符 / R2 account ID must contain 32 hexadecimal characters") }
            }
        } else {
            guard !(fields["refresh_token"] ?? "").isEmpty else { throw AppFailure("请先授权或导入 refresh_token / Authorize or import a refresh token first") }
        }
        return result
    }

    private static func validateURL(_ text: String, allowHTTP: Bool, endpointOnly: Bool) throws {
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URLComponents(string: text), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && allowHTTP),
              !endpointOnly || url.path.isEmpty || url.path == "/" else {
            throw AppFailure("请输入不含账号、查询参数的完整 HTTPS 地址；HTTP 需明确允许 / Enter a complete HTTPS URL without user info or query; HTTP requires explicit opt-in")
        }
    }

    public static func accountID(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let id = UInt64(value) else { throw AppFailure("请输入有效的 Steam AccountID 或 SteamID64 / Enter a valid Steam account ID or SteamID64") }
        if id > 0 && id < UInt32.max { return String(id) }
        let base: UInt64 = 76_561_197_960_265_728
        guard id > base, id - base < UInt32.max else { throw AppFailure("Steam 账号 ID 超出范围 / Steam account ID is out of range") }
        return String(id - base)
    }

    public static func decodeLast<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        guard let line = output.split(separator: "\n").last else { throw AppFailure("云引擎没有返回结果 / Cloud engine returned no result") }
        return try JSONDecoder().decode(type, from: Data(line.utf8))
    }
}

public struct CloudConnectionTest: Decodable, Sendable {
    public let success: Bool
    public let uploaded: Bool
    public let downloaded: Bool
    public let verified: Bool
    public let cleaned: Bool
    public let bytes: Int
    public let sha256: String
    public var fullyVerified: Bool { success && uploaded && downloaded && verified && cleaned && bytes > 0 && sha256.count == 64 }
}

public struct CloudRemoteApp: Decodable, Identifiable, Sendable {
    public let appID: String
    public let fileCount: Int
    public let totalSize: Int64
    public var id: String { appID }
    enum CodingKeys: String, CodingKey { case appID = "app_id", fileCount = "file_count", totalSize = "total_size" }
}
public struct CloudRemoteInventory: Decodable, Sendable {
    public let success: Bool
    public let apps: [CloudRemoteApp]
}
