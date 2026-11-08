#pragma once
#include <string>
#include <cstdint>
namespace ManifestProvider {
bool ValidTemplate(const std::string&);
bool Install();
void Remove();
bool Installed();
unsigned Served();
unsigned Fallbacks();
uint64_t ParseCode(const std::string&);
}
