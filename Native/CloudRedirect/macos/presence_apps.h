#pragma once
#include <string>
#include <unordered_map>
#include <cstdint>
namespace PresenceApps {
std::unordered_map<uint32_t,std::string> Parse(const std::string& text);
std::unordered_map<uint32_t,std::string> Read(const std::string& configPath = {});
}
