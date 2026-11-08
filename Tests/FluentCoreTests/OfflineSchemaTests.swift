import Foundation
import Testing
@testable import FluentCore

struct OfflineSchemaTests {
    @Test func definitionsRetainHiddenNamesButNeverPlayerUnlocks() throws {
        let input = Data(#"{"game":{"availableGameStats":{"achievements":[{"name":"A/../B","displayName":"Hidden title","description":"Detail","hidden":1,"achieved":1,"unlocktime":42,"icon":"http://cdn.akamai.steamstatic.com/steamcommunity/public/images/apps/480/a.jpg","icongray":"https://cdn.akamai.steamstatic.com/steamcommunity/public/images/apps/480/b.jpg"}]}}}"#.utf8)
        var schema = try OfflineSchema.parse(input)
        let path = try #require(OfflineSchema.imagePath(schema.definitions[0].icon))
        #expect(!path.contains("..")); #expect(path.hasPrefix("achievement_images/"))
        #expect(OfflineSchema.imageURL(schema.definitions[0].icon)?.scheme == "https")
        schema.images[path] = Data([1,2,3])
        let rows = try #require(JSONSerialization.jsonObject(with: schema.json()) as? [[String: Any]])
        #expect(rows[0]["name"] as? String == "A/../B")
        #expect(rows[0]["hidden"] as? Int == 1)
        #expect(rows[0]["icon"] as? String == path)
        #expect(rows[0]["icon_gray"] == nil)
        #expect(rows[0]["achieved"] == nil); #expect(rows[0]["unlocktime"] == nil)
    }
    @Test func malformedSchemasAndUntrustedImageLocationsAreRejected() throws {
        for raw in [#"{}"#, #"{"game":{"availableGameStats":{"achievements":"broken"}}}"#, #"{"game":{"availableGameStats":{"achievements":[{"name":"A"},{"name":"A"}]}}}"#] {
            #expect(throws: (any Error).self) { try OfflineSchema.parse(Data(raw.utf8)) }
        }
        #expect(try OfflineSchema.parse(Data(#"{"game":{"availableGameStats":{}}}"#.utf8)).definitions.isEmpty)
        for raw in ["file:///tmp/a.png", "https://steamstatic.com.evil.test/a.png", "https://user:secret@steamstatic.com/a.png", "https://steamstatic.com:8443/a.png", "https://steamstatic.com/a.exe"] {
            #expect(OfflineSchema.imagePath(raw) == nil)
        }
    }
}
