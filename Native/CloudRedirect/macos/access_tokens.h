#pragma once
#include <string>
#include <unordered_map>
#include <cstdint>
namespace AccessTokens {
std::unordered_map<uint32_t,uint64_t> Read();
std::unordered_map<uint32_t,uint64_t> Parse(const std::string&);
}
