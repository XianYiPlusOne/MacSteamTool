// SDK and system ABI only. The Swift session owns rooms, routing and packet formats.
#include "Multiplayer.h"
#include "steam_api.h"
#include "platform/tun/tun_privileged_helper.h"
#include <cstdio>
#include <fcntl.h>
#include <unistd.h>

namespace {
SteamNetworkingIdentity identity(uint64_t id) {
    SteamNetworkingIdentity value{};
    value.SetSteamID64(id);
    return value;
}
bool start(char *error, int32_t size) {
    SteamErrMsg diagnostic{};
    if (SteamAPI_InitEx(&diagnostic) != k_ESteamAPIInitResult_OK) {
        snprintf(error, size, "%s", diagnostic);
        return false;
    }
    if (!SteamUser() || !SteamFriends() || !SteamMatchmaking() || !SteamUtils() || !SteamNetworkingSockets() ||
        !SteamNetworkingMessages() || !SteamNetworkingUtils() || SteamUtils()->GetAppID() != 480 ||
        !SteamUser()->BLoggedOn()) {
        SteamAPI_Shutdown();
        snprintf(error, size, "Steam AppID 480 needs a signed-in client");
        return false;
    }
    SteamAPI_ManualDispatch_Init();
    auto *net = SteamNetworkingUtils();
    net->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_P2P_Transport_ICE_Implementation, 1);
    net->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_P2P_Transport_ICE_Enable,
                                   k_nSteamNetworkingConfig_P2P_Transport_ICE_Enable_Public |
                                       k_nSteamNetworkingConfig_P2P_Transport_ICE_Enable_Private);
    net->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_SendBufferSize, 2 * 1024 * 1024);
    net->InitRelayNetworkAccess();
    return true;
}
template <typename T> bool result(HSteamPipe pipe, const SteamAPICallCompleted_t &done, T &value) {
    bool failed = false;
    return SteamAPI_ManualDispatch_GetAPICallResult(pipe, done.m_hAsyncCall, &value, sizeof(value),
                                                    T::k_iCallback, &failed) &&
           !failed;
}
void poll(void *context, MPEventSink emit) {
    const auto pipe = SteamAPI_GetHSteamPipe();
    SteamAPI_ManualDispatch_RunFrame(pipe);
    CallbackMsg_t msg{};
    for (int count = 0; count < 256 && SteamAPI_ManualDispatch_GetNextCallback(pipe, &msg); ++count) {
        MPEvent e{};
        char chat[4096];
        int bytes = 0;
        switch (msg.m_iCallback) {
        case SteamAPICallCompleted_t::k_iCallback: {
            const auto &done = *reinterpret_cast<SteamAPICallCompleted_t *>(msg.m_pubParam);
            e.call = done.m_hAsyncCall;
            if (done.m_iCallback == LobbyCreated_t::k_iCallback) {
                LobbyCreated_t value{};
                e.kind = MP_CREATED;
                if (result(pipe, done, value) && value.m_eResult == k_EResultOK)
                    e.lobby = value.m_ulSteamIDLobby;
            } else if (done.m_iCallback == LobbyEnter_t::k_iCallback) {
                LobbyEnter_t value{};
                e.kind = MP_ENTERED;
                if (result(pipe, done, value) &&
                    value.m_EChatRoomEnterResponse == k_EChatRoomEnterResponseSuccess)
                    e.lobby = value.m_ulSteamIDLobby;
            } else if (done.m_iCallback == LobbyMatchList_t::k_iCallback) {
                LobbyMatchList_t value{};
                e.kind = MP_LIST;
                e.value = result(pipe, done, value) ? int(value.m_nLobbiesMatching) : -1;
            }
            break;
        }
        case LobbyChatMsg_t::k_iCallback: {
            auto &v = *reinterpret_cast<LobbyChatMsg_t *>(msg.m_pubParam);
            CSteamID sender;
            EChatEntryType type{};
            bytes = SteamMatchmaking()->GetLobbyChatEntry(v.m_ulSteamIDLobby, v.m_iChatID, &sender, chat,
                                                          sizeof(chat), &type);
            if (type == k_EChatEntryTypeChatMsg && bytes > 0 && bytes <= int(sizeof(chat))) {
                e.kind = MP_CHAT;
                e.lobby = v.m_ulSteamIDLobby;
                e.peer = sender.ConvertToUint64();
            }
            break;
        }
        case LobbyChatUpdate_t::k_iCallback:
            e.kind = MP_CHANGED;
            e.lobby = reinterpret_cast<LobbyChatUpdate_t *>(msg.m_pubParam)->m_ulSteamIDLobby;
            break;
        case LobbyDataUpdate_t::k_iCallback:
            e.kind = MP_CHANGED;
            e.lobby = reinterpret_cast<LobbyDataUpdate_t *>(msg.m_pubParam)->m_ulSteamIDLobby;
            break;
        case GameLobbyJoinRequested_t::k_iCallback:
            e.kind = MP_INVITED;
            e.lobby =
                reinterpret_cast<GameLobbyJoinRequested_t *>(msg.m_pubParam)->m_steamIDLobby.ConvertToUint64();
            break;
        case LobbyKicked_t::k_iCallback:
            e.kind = MP_KICKED;
            e.lobby = reinterpret_cast<LobbyKicked_t *>(msg.m_pubParam)->m_ulSteamIDLobby;
            break;
        case SteamNetConnectionStatusChangedCallback_t::k_iCallback: {
            auto &v = *reinterpret_cast<SteamNetConnectionStatusChangedCallback_t *>(msg.m_pubParam);
            e.kind = MP_CONNECTION;
            e.value = v.m_info.m_eState;
            e.connection = v.m_hConn;
            e.peer = v.m_info.m_identityRemote.GetSteamID64();
            e.listener = v.m_info.m_hListenSocket;
            break;
        }
        case SteamNetworkingMessagesSessionRequest_t::k_iCallback:
            e.kind = MP_REQUEST;
            e.peer = reinterpret_cast<SteamNetworkingMessagesSessionRequest_t *>(msg.m_pubParam)
                         ->m_identityRemote.GetSteamID64();
            break;
        case SteamNetworkingMessagesSessionFailed_t::k_iCallback:
            e.kind = MP_SESSION_FAILED;
            e.peer = reinterpret_cast<SteamNetworkingMessagesSessionFailed_t *>(msg.m_pubParam)
                         ->m_info.m_identityRemote.GetSteamID64();
            break;
        case SteamShutdown_t::k_iCallback:
            e.kind = MP_STEAM_LOST;
            break;
        }
        if (e.kind)
            emit(context, e, e.kind == MP_CHAT ? chat : nullptr, e.kind == MP_CHAT ? bytes : 0);
        SteamAPI_ManualDispatch_FreeLastCallback(pipe);
    }
}
void deliver(SteamNetworkingMessage_t **messages, int count, void *context, MPPacketSink sink) {
    for (int i = 0; i < count; ++i) {
        auto *msg = messages[i];
        sink(context, msg->m_identityPeer.GetSteamID64(), msg->m_pData, msg->m_cbSize);
        msg->Release();
    }
}
const MPFunctions functions = {
    .start = start,
    .stop = SteamAPI_Shutdown,
    .poll = poll,
    .user = []() -> uint64_t {
        return SteamAPI_IsSteamRunning() && SteamUser()->BLoggedOn()
                   ? SteamUser()->GetSteamID().ConvertToUint64()
                   : 0;
    },
    .name = [](uint64_t id) { return SteamFriends()->GetFriendPersonaName(id); },
    .create = [](int32_t slots) -> uint64_t {
        return SteamMatchmaking()->CreateLobby(k_ELobbyTypePublic, slots);
    },
    .join = [](uint64_t id) -> uint64_t { return SteamMatchmaking()->JoinLobby(id); },
    .leave = [](uint64_t id) { SteamMatchmaking()->LeaveLobby(id); },
    .owner = [](uint64_t id) -> uint64_t { return SteamMatchmaking()->GetLobbyOwner(id).ConvertToUint64(); },
    .memberCount = [](uint64_t id) { return SteamMatchmaking()->GetNumLobbyMembers(id); },
    .member = [](uint64_t id, int32_t i) -> uint64_t {
        return SteamMatchmaking()->GetLobbyMemberByIndex(id, i).ConvertToUint64();
    },
    .metadata = [](uint64_t id, const char *key) { return SteamMatchmaking()->GetLobbyData(id, key); },
    .setMetadata =
        [](uint64_t id, const char *key, const char *value) {
            return value ? SteamMatchmaking()->SetLobbyData(id, key, value)
                         : SteamMatchmaking()->DeleteLobbyData(id, key);
        },
    .chat = [](uint64_t id, const void *data,
               int32_t n) { return SteamMatchmaking()->SendLobbyChatMsg(id, data, n); },
    .invite = [](uint64_t lobby, uint64_t peer) { return SteamMatchmaking()->InviteUserToLobby(lobby, peer); },
    .list = [](const char *key, const char *value) -> uint64_t {
        auto *mm = SteamMatchmaking();
        mm->AddRequestLobbyListStringFilter(key, value, k_ELobbyComparisonEqual);
        mm->AddRequestLobbyListDistanceFilter(k_ELobbyDistanceFilterWorldwide);
        mm->AddRequestLobbyListResultCountFilter(100);
        return mm->RequestLobbyList();
    },
    .listedLobby = [](int32_t i) -> uint64_t {
        return SteamMatchmaking()->GetLobbyByIndex(i).ConvertToUint64();
    },
    .friendCount = [] { return SteamFriends()->GetFriendCount(k_EFriendFlagImmediate); },
    .friendAt = [](int32_t i) -> uint64_t {
        return SteamFriends()->GetFriendByIndex(i, k_EFriendFlagImmediate).ConvertToUint64();
    },
    .personaState = [](uint64_t id) { return int(SteamFriends()->GetFriendPersonaState(id)); },
    .isFriend = [](uint64_t id) { return SteamFriends()->HasFriend(id, k_EFriendFlagImmediate); },
    .presence = [](uint64_t id, const char *key) { return SteamFriends()->GetFriendRichPresence(id, key); },
    .setPresence = [](const char *key, const char *v) { return SteamFriends()->SetRichPresence(key, v); },
    .listen = [] { return SteamNetworkingSockets()->CreateListenSocketP2P(0, 0, nullptr); },
    .closeListen = [](uint32_t h) { SteamNetworkingSockets()->CloseListenSocket(h); },
    .connect =
        [](uint64_t peer, bool relayOnly) {
            SteamNetworkingConfigValue_t option;
            option.SetInt32(k_ESteamNetworkingConfig_P2P_Transport_ICE_Enable, 0);
            return SteamNetworkingSockets()->ConnectP2P(identity(peer), 0, relayOnly ? 1 : 0,
                                                        relayOnly ? &option : nullptr);
        },
    .accept = [](uint32_t h) { return SteamNetworkingSockets()->AcceptConnection(h) == k_EResultOK; },
    .closeTCP = [](uint32_t h) { SteamNetworkingSockets()->CloseConnection(h, 0, nullptr, false); },
    .sendTCP =
        [](uint32_t h, const void *b, int32_t n) {
            return int(SteamNetworkingSockets()->SendMessageToConnection(
                h, b, n, k_nSteamNetworkingSend_ReliableNoNagle, nullptr));
        },
    .readTCP =
        [](uint32_t h, void *ctx, MPPacketSink sink) {
            SteamNetworkingMessage_t *msgs[32];
            int n = SteamNetworkingSockets()->ReceiveMessagesOnConnection(h, msgs, 32);
            deliver(msgs, n, ctx, sink);
        },
    .acceptVPN = [](uint64_t peer) { return SteamNetworkingMessages()->AcceptSessionWithUser(identity(peer)); },
    .closeVPN = [](uint64_t peer) { SteamNetworkingMessages()->CloseSessionWithUser(identity(peer)); },
    .sendVPN =
        [](uint64_t peer, const void *b, int32_t n, bool reliable, bool restart) {
            int flags = reliable ? k_nSteamNetworkingSend_Reliable
                                 : k_nSteamNetworkingSend_UnreliableNoNagle | k_nSteamNetworkingSend_NoDelay;
            if (restart)
                flags |= k_nSteamNetworkingSend_AutoRestartBrokenSession;
            return SteamNetworkingMessages()->SendMessageToUser(identity(peer), b, n, flags, 0) == k_EResultOK;
        },
    .readVPN =
        [](void *ctx, MPPacketSink sink) {
            SteamNetworkingMessage_t *msgs[64];
            int n = SteamNetworkingMessages()->ReceiveMessagesOnChannel(0, msgs, 64);
            deliver(msgs, n, ctx, sink);
        },
    .connectionPing =
        [](uint32_t h, bool *relay) {
            SteamNetConnectionInfo_t info{};
            SteamNetConnectionRealTimeStatus_t status{};
            if (!SteamNetworkingSockets()->GetConnectionInfo(h, &info) ||
                SteamNetworkingSockets()->GetConnectionRealTimeStatus(h, &status, 0, nullptr) != k_EResultOK)
                return -1;
            *relay = (info.m_nFlags & k_nSteamNetworkConnectionInfoFlags_Relayed) != 0;
            return status.m_nPing;
        },
    .vpnPing =
        [](uint64_t peer, bool *relay) {
            SteamNetConnectionInfo_t info{};
            SteamNetConnectionRealTimeStatus_t status{};
            if (SteamNetworkingMessages()->GetSessionConnectionInfo(identity(peer), &info, &status) !=
                k_ESteamNetworkingConnectionState_Connected)
                return -1;
            *relay = (info.m_nFlags & k_nSteamNetworkConnectionInfoFlags_Relayed) != 0;
            return status.m_nPing;
        },
    .pingLocation =
        [](char *out, int32_t n) {
            SteamNetworkPingLocation_t location{};
            if (SteamNetworkingUtils()->GetLocalPingLocation(location) < 0)
                return false;
            SteamNetworkingUtils()->ConvertPingLocationToString(location, out, n);
            return true;
        },
    .estimatePing =
        [](const char *text) {
            SteamNetworkPingLocation_t location{};
            return SteamNetworkingUtils()->ParsePingLocationString(text, location)
                       ? SteamNetworkingUtils()->EstimatePingTimeFromLocalHost(location)
                       : -1;
        },
    .popList = [](uint32_t *out, int32_t n) { return SteamNetworkingUtils()->GetPOPList(out, n); },
    .popPing = [](uint32_t pop,
                  uint32_t *via) { return SteamNetworkingUtils()->GetPingToDataCenter(pop, via); },
    .avatar =
        [](uint64_t id, uint8_t *out, int32_t size) {
            int h = SteamFriends()->GetSmallFriendAvatar(id);
            uint32_t w = 0, height = 0;
            if (h <= 0 || !SteamUtils()->GetImageSize(h, &w, &height) || w != height || w > 64 || !w ||
                int(w * w * 4) > size)
                return 0;
            return SteamUtils()->GetImageRGBA(h, out, size) ? int(w) : 0;
        },
    .openTun =
        [](char *name, int32_t cap, char *error, int32_t n) {
            tun::HelperOpenResult out;
            if (!tun::helperOpen("SteamVPN", 1400, &out)) {
                snprintf(error, n, "%s", out.error.c_str());
                return -1;
            }
            if (fcntl(out.fd, F_SETFL, O_NONBLOCK) < 0 || fcntl(out.fd, F_SETFD, FD_CLOEXEC) < 0) {
                close(out.fd);
                snprintf(error, n, "Cannot configure utun descriptor");
                return -1;
            }
            snprintf(name, cap, "%s", out.interfaceName.c_str());
            return out.fd;
        },
    .configureTun =
        [](const char *name, const char *ip, char *error, int32_t n) {
            std::string msg;
            bool ok = tun::helperSetIp(name, ip, "255.0.0.0", &msg) && tun::helperSetUp(name, true, &msg) &&
                      tun::helperAddRoute("10.0.0.0", "255.0.0.0", name, &msg);
            if (!ok)
                snprintf(error, n, "%s", msg.c_str());
            return ok;
        },
};
} // namespace

extern "C" __attribute__((visibility("default"))) const MPFunctions *MacMultiplayerBindingsV1() {
    return &functions;
}
