import Foundation

/// Privileged changes are limited to ConnectTool's helper and launchd job.
/// The executable and plist are pinned before authorization and checked again
/// after being copied into a root-owned staging directory.
public enum TunHelperSetup {
    public static let service = "com.connecttool.tunhelper"
    public static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func appleScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
    public static func installScript(helper: URL, plist: URL, helperHash: String, plistHash: String) throws -> String {
        func validHash(_ hash: String) -> Bool { hash.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard helper.isFileURL, plist.isFileURL, !helper.path.contains("\0"), !plist.path.contains("\0"), validHash(helperHash), validHash(plistHash) else { throw AppFailure("无效的网卡助手安装文件 / Invalid TUN helper assets") }
        return """
        set -eu
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin
        unset CONNECTTOOL_TUN_HELPER_SOCKET DYLD_LIBRARY_PATH DYLD_INSERT_LIBRARIES
        umask 077
        helper=/Library/PrivilegedHelperTools/connecttool-tun-daemon
        plist=/Library/LaunchDaemons/com.connecttool.tunhelper.plist
        service=system/com.connecttool.tunhelper
        /bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons
        stage=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.fluent-connecttool.XXXXXX)
        changed=0
        loaded=0
        rollback() {
            result=$?
            trap - EXIT
            if [ "$result" -ne 0 ] && [ "$changed" -eq 1 ]; then
                /bin/launchctl bootout "$service" >/dev/null 2>&1 || :
                if [ -f "$stage/old-helper" ]; then /bin/mv -f "$stage/old-helper" "$helper"; else /bin/rm -f "$helper"; fi
                if [ -f "$stage/old-plist" ]; then /bin/mv -f "$stage/old-plist" "$plist"; else /bin/rm -f "$plist"; fi
                if [ "$loaded" -eq 1 ]; then /bin/launchctl bootstrap system "$plist" || echo 'Previous helper could not be restarted' >&2; fi
            fi
            /bin/rm -rf "$stage"
            exit "$result"
        }
        trap rollback EXIT
        /usr/bin/install -o root -g wheel -m 755 \(shellQuote(helper.path)) "$stage/helper"
        /usr/bin/install -o root -g wheel -m 644 \(shellQuote(plist.path)) "$stage/plist"
        test "$(/usr/bin/shasum -a 256 "$stage/helper" | /usr/bin/cut -d ' ' -f 1)" = \(shellQuote(helperHash))
        test "$(/usr/bin/shasum -a 256 "$stage/plist" | /usr/bin/cut -d ' ' -f 1)" = \(shellQuote(plistHash))
        /usr/bin/codesign --verify --strict "$stage/helper"
        /usr/bin/plutil -lint "$stage/plist"
        if [ -f "$helper" ]; then /bin/cp -p "$helper" "$stage/old-helper"; fi
        if [ -f "$plist" ]; then /bin/cp -p "$plist" "$stage/old-plist"; fi
        if /bin/launchctl print "$service" >/dev/null 2>&1; then
            loaded=1
            /bin/launchctl bootout "$service"
        fi
        changed=1
        /bin/mv -f "$stage/helper" "$helper"
        /bin/mv -f "$stage/plist" "$plist"
        /bin/launchctl enable "$service"
        /bin/launchctl bootstrap system "$plist"
        /bin/launchctl kickstart -k "$service"
        /bin/launchctl print "$service" >/dev/null
        # Wait for the daemon socket, then create and release an actual utun.
        attempts=0
        until "$helper" --probe; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 5 ]; then echo 'Virtual network helper failed its device check' >&2; exit 1; fi
            /bin/sleep 1
        done
        changed=0
        """
    }
}
