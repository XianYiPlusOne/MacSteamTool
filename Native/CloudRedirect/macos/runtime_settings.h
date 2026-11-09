#pragma once
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <string>
#include <vector>
#include <cstdint>
namespace RuntimeSettings {
struct Ticket {uint32_t app=0,signature=0;uint64_t steamID=0;std::vector<uint8_t> ownership,encrypted;};
struct Manifest {std::string mode="macsteam",url;std::unordered_set<uint32_t> apps;};
struct Configuration {Manifest manifest;std::string presence="automatic";std::unordered_map<uint32_t,std::string> presenceApps,managedApps;std::unordered_map<uint32_t,Ticket> tickets;std::unordered_map<uint32_t,uint64_t> accessTokens;std::vector<uint64_t> presenceShortcuts;uint32_t presenceAccount=0;};
std::shared_ptr<const Configuration> Current();
void Reload();
void Start();
void Stop();
}
