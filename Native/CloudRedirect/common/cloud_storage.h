#pragma once
#include "cloud_provider.h"
#include <functional>

namespace CloudStorage {

void InitStatistics(std::unique_ptr<ICloudProvider> provider);
void Shutdown();
bool IsCloudActive();

struct InflightSyncScope {
    bool entered = false;
    InflightSyncScope();
    ~InflightSyncScope();
    explicit operator bool() const { return entered; }
    InflightSyncScope(const InflightSyncScope&) = delete;
    InflightSyncScope& operator=(const InflightSyncScope&) = delete;
};
std::string CloudMetadataPath(uint32_t accountId, uint32_t appId, const std::string& name);
bool DownloadLegacyStats(uint32_t accountId, uint32_t appId, std::vector<uint8_t>& data);
enum class MetadataFetch { Ok, Missing, Error };
MetadataFetch FetchCloudMetadataStatus(uint32_t accountId, uint32_t appId,
    const char* canonicalName, std::vector<uint8_t>& outData);
// Download the first-format per-app playtime blob (account-scope
// <acct>/0/blobs/Playtime/<appId>.bin). False if absent/unavailable. Migration-only.
bool DownloadLegacyPlaytimeBlob(uint32_t accountId, uint32_t appId,
    std::vector<uint8_t>& outData);
bool UploadCloudMetadataText(uint32_t accountId, uint32_t appId,
    const char* name, const std::string& content);
// Re-read/re-merge on conditional-write conflicts. The callback must be pure.
bool MergeCloudMetadataText(uint32_t accountId, uint32_t appId, const char* name,
    const std::function<bool(const std::string&, std::string&)>& merge);

} // namespace CloudStorage
