#pragma once
#include "cloud_provider.h"
#include <functional>
namespace StatsJournal {
struct Snapshot { std::string merged; std::vector<std::string> included; bool exists=false; int64_t generation=0; };
bool Read(ICloudProvider&, const std::string& path, Snapshot&);
bool Publish(ICloudProvider&,const std::string& path,const std::function<bool(const std::string&,std::string&)>& merge);
}
