#import <Foundation/Foundation.h>
#include <string>
namespace ManifestProvider {
std::string JSONCode(const std::string& text) {
    @autoreleasepool {
        NSData* data = [NSData dataWithBytes:text.data() length:text.size()];
        id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![root isKindOfClass:[NSDictionary class]]) return {};
        id value = root[@"manifest_request_code"] ?: root[@"content"];
        NSString* digits = nil;
        if ([value isKindOfClass:[NSString class]]) digits = value;
        else if ([value isKindOfClass:[NSNumber class]] && CFGetTypeID((CFTypeRef)value) != CFBooleanGetTypeID()) digits = [value stringValue];
        // Keep UInt64 text exact; do not round the request code through double.
        if (!digits || [digits length] > 20) return {};
        const char* utf8 = [digits UTF8String];
        return utf8 ? std::string(utf8, [digits lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) : std::string();
    }
}
}
