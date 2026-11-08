#pragma once
#include <cstdint>
#include <cstddef>
namespace TicketHooks {
bool Install(uintptr_t base,size_t size);
void Remove();
bool Installed();
unsigned OwnershipServed();
unsigned EncryptedServed();
unsigned CallbacksServed();
}
