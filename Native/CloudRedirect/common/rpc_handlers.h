#pragma once
#include "protobuf.h"
#include <utility>

namespace CloudIntercept {

// Steam EResult values used by the cloud RPC layer.
inline constexpr int32_t kEResultOK       = 1;
inline constexpr int32_t kEResultFail     = 2;
inline constexpr int32_t kEResultDisabled = 108;

// RPC response: body bytes + optional EResult override.
struct RpcResult {
    PB::Writer body;
    int32_t    eresult = kEResultOK;

    RpcResult() = default;
    RpcResult(PB::Writer b) : body(std::move(b)) {}
    RpcResult(PB::Writer b, int32_t er) : body(std::move(b)), eresult(er) {}
};

} // namespace CloudIntercept
