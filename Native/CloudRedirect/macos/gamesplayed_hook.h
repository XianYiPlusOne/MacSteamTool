#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

// Observes CCMInterface::Send for playtime tracking and achievement capture.

namespace GamesPlayedHook {

using SerializeBodyFn = const uint8_t* (*)(void* bodyObj, size_t* outLen);
void SetSerializer(SerializeBodyFn fn);

bool Install(uintptr_t steamclientBase, size_t steamclientSize);
void Remove();
bool Installed();
bool FilterPresence(uint32_t message,const std::vector<uint8_t>& input,std::vector<uint8_t>& output);
bool SuppressRichPresence(uint32_t appID);
bool ApplyAccessTokens(uint32_t message,const std::vector<uint8_t>& input,std::vector<uint8_t>& output);
unsigned TokenRequests();
unsigned Observed();
unsigned Rewritten();
unsigned Sent();
unsigned Failed();
uint32_t LastApp();
uint64_t LastGameID();
uint64_t LastAttemptedGameID();
uint64_t LastSentAt();

} // namespace GamesPlayedHook
