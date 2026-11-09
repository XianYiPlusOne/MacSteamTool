using SteamKit2;
using SteamKit2.Authentication;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

internal sealed class LoginAuthenticator(string status, CancellationToken ct) : IAuthenticator
{
    public Task<bool> AcceptDeviceConfirmationAsync() => Task.FromResult(false);
    public Task<string> GetDeviceCodeAsync(bool previousCodeWasIncorrect) => Ask(previousCodeWasIncorrect ? "设备验证码错误，请重新输入 / Incorrect device code; try again" : "请输入 Steam Guard 设备验证码 / Enter Steam Guard device code");
    public Task<string> GetEmailCodeAsync(string email, bool previousCodeWasIncorrect) => Ask(previousCodeWasIncorrect ? "邮箱验证码错误，请重新输入 / Incorrect email code; try again" : "请输入 Steam 邮箱验证码 / Enter Steam email code");
    async Task<string> Ask(string prompt)
    {
        var id = Guid.NewGuid().ToString("N");
        Program.Write(status, new { state = "guard", requestID = id, prompt });
        var reply = status + ".reply";
        while (true) {
            ct.ThrowIfCancellationRequested();
            if (File.Exists(reply)) {
                using var json = JsonDocument.Parse(await File.ReadAllTextAsync(reply, ct));
                if (json.RootElement.GetProperty("requestID").GetString() == id) {
                    var code = json.RootElement.GetProperty("code").GetString(); File.Delete(reply);
                    if (string.IsNullOrWhiteSpace(code)) throw new OperationCanceledException();
                    return code.Trim();
                }
            }
            await Task.Delay(150, ct);
        }
    }
}
internal static class LocalSteamLogin
{
    // macOS/Linux ConnectCache envelope: SHA256(username), ECB-encrypted IV,
    // followed by CBC data with PKCS7 padding. Unknown envelopes fail closed.
    internal static string? Decrypt(byte[] blob, string account, string steamID, DateTimeOffset now)
    {
        if (blob.Length < 32 || blob.Length > 16384 || blob.Length % 16 != 0) return null;
        try {
            using var aes = Aes.Create(); aes.Key = SHA256.HashData(Encoding.UTF8.GetBytes(account));
            var iv = aes.DecryptEcb(blob.AsSpan(0, 16), PaddingMode.None);
            var plain = aes.DecryptCbc(blob.AsSpan(16), iv, PaddingMode.PKCS7);
            try {
                var token = Encoding.UTF8.GetString(plain); var parts = token.Split('.');
                if (parts.Length != 3) return null;
                var encoded = parts[1].Replace('-', '+').Replace('_', '/'); encoded = encoded.PadRight((encoded.Length + 3) / 4 * 4, '=');
                using var payload = JsonDocument.Parse(Convert.FromBase64String(encoded));
                if (payload.RootElement.GetProperty("sub").GetString() != steamID || payload.RootElement.GetProperty("exp").GetInt64() <= now.ToUnixTimeSeconds()) return null;
                return token;
            } finally { CryptographicOperations.ZeroMemory(plain); }
        } catch { return null; }
    }
    internal static string Read(Request request)
    {
        if (!Path.IsPathFullyQualified(request.SteamPath) || !ulong.TryParse(request.SteamID, out var sid) || sid == 0 || string.IsNullOrWhiteSpace(request.Account)) throw new Exception("Invalid local Steam account");
        foreach (var relative in new[] { "local.vdf", "config/local.vdf" }) {
            var path = Path.Combine(request.SteamPath, relative);
            if (!File.Exists(path)) continue;
            var info = new FileInfo(path);
            if (info.LinkTarget != null || info.Length > 4 * 1024 * 1024) continue;
            using var stream = File.OpenRead(path);
            var root = new KeyValue(); if (!root.ReadAsText(stream)) continue;
            KeyValue? Child(KeyValue? parent, string key) => parent?.Children.FirstOrDefault(x => string.Equals(x.Name, key, StringComparison.OrdinalIgnoreCase));
            var cache = Child(Child(Child(Child(root, "Software"), "Valve"), "Steam"), "ConnectCache");
            foreach (var value in cache?.Children ?? []) {
                try {
                    var blob = Convert.FromHexString(value.Value ?? "");
                    var token = Decrypt(blob, request.Account, request.SteamID, DateTimeOffset.UtcNow);
                    if (token != null) return token;
                } catch { }
            }
        }
        throw new Exception("没有找到所选账号可用的本机凭证，请使用密码或扫码登录 / No supported, unexpired local credential for this account; use password or QR sign-in");
    }
}
