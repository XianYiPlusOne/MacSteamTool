import Foundation

public enum OwnedExport {
    public static func files(_ response: SteamEngineResponse, steam: URL, includeSchema: Bool) throws -> (files: [ImportFile], warnings: [String]) {
        let lua = try response.lua()
        guard let id = response.appID else { throw AppFailure("提取结果没有 AppID / Extraction result has no AppID") }
        var files = [ImportFile(name: "\(id).lua", data: Data(lua.utf8))]
        var warnings = response.warnings ?? []
        if includeSchema {
            // Only the app definition, never UserGameStats_<account>_<app>.bin.
            let name = "UserGameStatsSchema_\(id).bin", file = steam.appendingPathComponent("appcache/stats/\(name)")
            if !FileStore.fm.fileExists(atPath: file.path) { warnings.append("\(id): 本机没有成就定义 Bin / Local achievement schema Bin is missing") }
            else {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= 64 * 1024 * 1024 else { throw AppFailure("本地成就定义文件无效 / Invalid local achievement schema file") }
                files.append(ImportFile(name: name, data: try FileStore.read(file)))
            }
        }
        return (files, warnings)
    }
}
