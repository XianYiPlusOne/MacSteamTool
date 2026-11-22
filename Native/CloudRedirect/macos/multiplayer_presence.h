#pragma once
#include "protobuf.h"

namespace MultiplayerPresence {
// Keep a standalone helper visible. In a mixed session keep the games in their
// original order so the usual privacy and most-recent-game rules still apply.
bool PreferGames(std::vector<PB::Field>& fields);
}
