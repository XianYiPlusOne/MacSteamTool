// Local Steam boundary for driving the real Swift controller. All peer traffic
// below uses the upstream 1.6.0 encoder/decoder, independently of Swift.
#include "Multiplayer.h"
#include "network/protocol/multiplex_protocol.h"
#include "network/protocol/wire_codec.h"
#include "network/vpn/ip_negotiator.h"
#include <arpa/inet.h>
#include <deque>
#include <fcntl.h>
#include <map>
#include <string>
#include <unistd.h>
using namespace connecttool;
using Bytes = std::vector<std::byte>;
using VPN = wire::VpnMessageType;
constexpr uint64_t me = 76561198012345678ULL, peer = me + 1, room = 109775241000000001ULL;
static uint32_t remoteIP = 0;
static IpNegotiator originalNegotiator;
static bool probing = false, injectedIP = false;
static const auto remoteNode = NodeIdentity::generate(domain::PeerId{peer});
static std::deque<std::pair<MPEvent, Bytes>> events;
static std::map<std::string, std::string> metadata;
static std::deque<Bytes> vpnQueue;
static std::map<uint32_t, std::deque<Bytes>> tcpQueue;
static std::string presence;
static bool hosting = false, tunMode = false;
static bool signedIn = true, sdkRunning = false;
static int startAttempts = 0, memberCount = 2;
static uint32_t localIP;
static int tunPair[2] = {-1, -1}, listener = -1, gamePort = 0;
static std::vector<int> gameClients;
static bool joinTCP = false;
static uint16_t guestPort = 0;
static int guestSocket = -1, guestBytes = 0, guestClose = 0;
static std::string guestReceived;
static const std::string payload(3407, 'Z');
static int errors = 0, tcpReturned = 0, tcpClosed = 0, ipSent = 0, ipReceived = 0, left = 0, stops = 0,
           invites = 0;
static void check(bool ok) {
    if (!ok)
        ++errors;
}
static void event(MPEvent e) { events.emplace_back(e, Bytes{}); }
static void nonblock(int fd) { fcntl(fd, F_SETFL, O_NONBLOCK); }

static Bytes ipPacket(uint32_t src, uint32_t dst) {
    Bytes packet(24);
    packet[0] = std::byte{0x45};
    packet[3] = std::byte{24};
    packet[8] = std::byte{64};
    packet[9] = std::byte{17};
    src = htonl(src);
    dst = htonl(dst);
    memcpy(packet.data() + 12, &src, 4);
    memcpy(packet.data() + 16, &dst, 4);
    packet[23] = std::byte{0x9a};
    return packet;
}
static void pumpGame() {
    if (listener >= 0) {
        int fd = accept(listener, nullptr, nullptr);
        if (fd >= 0) {
            nonblock(fd);
            gameClients.push_back(fd);
        }
        for (int client : gameClients) {
            char buf[512];
            auto n = recv(client, buf, sizeof(buf), 0);
            if (n > 0)
                check(send(client, buf, n, 0) == n);
        }
    }
    if (guestSocket >= 0) {
        char buf[8192];
        auto n = recv(guestSocket, buf, sizeof(buf), 0);
        if (n > 0)
            guestReceived.append(buf, size_t(n));
        if (guestReceived.size() == payload.size()) {
            check(guestReceived == payload);
            close(guestSocket);
            guestSocket = -1;
        }
    }
    if (probing)
        originalNegotiator.checkTimeout();
    if (tunPair[1] >= 0 && localIP && remoteIP && !injectedIP) {
        auto packet = ipPacket(localIP, remoteIP);
        uint32_t family = htonl(AF_INET);
        Bytes frame(4);
        memcpy(frame.data(), &family, 4);
        frame.insert(frame.end(), packet.begin(), packet.end());
        check(send(tunPair[1], frame.data(), frame.size(), 0) == ssize_t(frame.size()));
        injectedIP = true;
    }
    if (tunPair[1] >= 0 && localIP) {
        std::byte buf[128];
        auto n = recv(tunPair[1], buf, sizeof(buf), 0);
        if (n > 0) {
            uint32_t family = htonl(AF_INET);
            auto expected = ipPacket(remoteIP, localIP);
            check(n == expected.size() + 4 && memcmp(buf, &family, 4) == 0 &&
                  memcmp(buf + 4, expected.data(), expected.size()) == 0);
            ++ipReceived;
        }
    }
}
static int openGame() {
    listener = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    check(bind(listener, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0);
    check(listen(listener, 8) == 0);
    nonblock(listener);
    socklen_t size = sizeof(addr);
    getsockname(listener, reinterpret_cast<sockaddr *>(&addr), &size);
    return ntohs(addr.sin_port);
}
static void injectTCP() {
    for (uint32_t h : {41u, 42u}) {
        event({.kind = MP_CONNECTION, .value = 1, .peer = peer + h, .connection = h, .listener = 17});
        event({.kind = MP_CONNECTION, .value = 3, .peer = peer + h, .connection = h, .listener = 17});
        auto id = *multiplex::ConnectionId::parse("aB12z9");
        tcpQueue[h].push_back(multiplex::encodeFrame(id, multiplex::PacketType::Data,
                                                     Bytes{std::byte(h), std::byte{0}, std::byte{0xa5}}));
    }
}

extern "C" int MPFixture(int command) {
    switch (command) {
    case 0:
        return errors;
    case 1:
        gamePort = openGame();
        return gamePort;
    case 2:
        injectTCP();
        return 0;
    case 3:
        return tcpReturned;
    case 4:
        return metadata["ct_tag"] == "1" && metadata["ct_mode"] == "tcp" && metadata["ct_name"] == "测试房间" &&
               metadata["ct_host_id"] == std::to_string(me) && metadata["ct_host_name"] == "Mac" &&
               metadata["ct_ping_loc"] == "location";
    case 5:
        return ipSent && ipReceived;
    case 6:
        return left;
    case 7:
        return stops;
    case 8:
        return invites;
    case 9:
        return tcpClosed;
    case 10:
        for (uint32_t h : {41u, 42u}) {
            auto id = *multiplex::ConnectionId::parse("aB12z9");
            tcpQueue[h].push_back(multiplex::encodeFrame(id, multiplex::PacketType::Disconnect));
        }
        return 0;
    case 11:
        return metadata["ct_pin"].find("steamId") != std::string::npos;
    case 12:
        return presence.empty();
    case 13: {
        joinTCP = true;
        auto fd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        check(bind(fd, reinterpret_cast<sockaddr *>(&a), sizeof(a)) == 0);
        socklen_t size = sizeof(a);
        getsockname(fd, reinterpret_cast<sockaddr *>(&a), &size);
        guestPort = ntohs(a.sin_port);
        close(fd);
        return guestPort;
    }
    case 14: {
        auto fd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        a.sin_port = htons(guestPort);
        if (connect(fd, reinterpret_cast<sockaddr *>(&a), sizeof(a)) != 0) {
            close(fd);
            return 0;
        }
        check(send(fd, payload.data(), payload.size(), 0) == ssize_t(payload.size()));
        nonblock(fd);
        guestSocket = fd;
        return 1;
    }
    case 15:
        return guestClose == 1 && guestBytes == int(payload.size()) && guestReceived == payload;
    case 16:
        joinTCP = false;
        return 0;
    case 17:
        signedIn = false;
        if (sdkRunning) event({.kind = MP_STEAM_LOST});
        return 0;
    case 18:
        signedIn = true;
        return 0;
    case 19:
        return startAttempts;
    case 20:
    case 21:
        memberCount = command == 20 ? 1 : 2;
        event({.kind = MP_CHANGED, .lobby = room});
        return 0;
    }
    return -1;
}

extern "C" const MPFunctions *MacMultiplayerBindingsV1() {
    static MPFunctions f{};
    f.start = [](char *, int32_t) {
        check(std::string(getenv("SteamAppId")) == "480");
        ++startAttempts;
        sdkRunning = signedIn;
        return sdkRunning;
    };
    f.stop = [] {
        sdkRunning = false;
        ++stops;
        events.clear();
        vpnQueue.clear();
        tcpQueue.clear();
        if (listener >= 0) {
            close(listener);
            listener = -1;
        }
        for (int fd : gameClients)
            close(fd);
        gameClients.clear();
        if (tunPair[1] >= 0) {
            close(tunPair[1]);
            tunPair[1] = -1;
        }
    };
    f.poll = [](void *ctx, MPEventSink sink) {
        pumpGame();
        while (!events.empty()) {
            auto [e, b] = std::move(events.front());
            events.pop_front();
            sink(ctx, e, b.data(), int(b.size()));
        }
    };
    f.user = []() { return me; };
    f.name = [](uint64_t id) { return id == me ? "Mac" : "Peer"; };
    f.create = [](int32_t n) -> uint64_t {
        check(n == 250);
        hosting = true;
        metadata.clear();
        event({.kind = MP_CREATED, .call = 11, .lobby = room});
        return 11;
    };
    f.join = [](uint64_t id) -> uint64_t {
        check(id == room);
        hosting = false;
        tunMode = !joinTCP;
        metadata = {{"ct_mode", joinTCP ? "tcp" : "tun"}, {"ct_name", "原版房间"}};
        event({.kind = MP_ENTERED, .call = 12, .lobby = room});
        return 12;
    };
    f.leave = [](uint64_t id) {
        check(id == room);
        ++left;
    };
    f.owner = [](uint64_t) { return hosting ? me : peer; };
    f.memberCount = [](uint64_t) { return memberCount; };
    f.member = [](uint64_t, int32_t i) { return i ? peer : me; };
    f.metadata = [](uint64_t, const char *key) { return metadata[key].c_str(); };
    f.setMetadata = [](uint64_t id, const char *k, const char *v) {
        check(id == room);
        if (v)
            metadata[k] = v;
        else
            metadata.erase(k);
        return true;
    };
    f.chat = [](uint64_t id, const void *b, int32_t n) {
        check(id == room);
        std::string text(static_cast<const char *>(b), n);
        if (text.starts_with("PING|"))
            return true;
        check(text == "你好，Steam");
        auto p = static_cast<const std::byte *>(b);
        events.emplace_back(MPEvent{.kind = MP_CHAT, .lobby = room, .peer = me}, Bytes(p, p + n));
        return true;
    };
    f.invite = [](uint64_t id, uint64_t p) {
        check(id == room && p == peer);
        ++invites;
        return true;
    };
    f.list = [](const char *k, const char *v) -> uint64_t {
        check(std::string(k) == "ct_tag" && std::string(v) == "1");
        event({.kind = MP_LIST, .value = 1, .call = 13});
        return 13;
    };
    f.listedLobby = [](int32_t) { return room; };
    f.friendCount = []() { return 1; };
    f.friendAt = [](int32_t) { return peer; };
    f.personaState = [](uint64_t) { return 1; };
    f.isFriend = [](uint64_t) { return true; };
    f.presence = [](uint64_t, const char *) { return presence.c_str(); };
    f.setPresence = [](const char *k, const char *v) {
        check(std::string(k) == "connect");
        presence = v ? v : "";
        return true;
    };
    f.listen = []() { return 17u; };
    f.closeListen = [](uint32_t h) { check(h == 17); };
    f.accept = [](uint32_t) { return true; };
    f.closeTCP = [](uint32_t) { ++tcpClosed; };
    f.connect = [](uint64_t p, bool relay) {
        check(p == peer && !relay);
        event({.kind = MP_CONNECTION, .value = 3, .peer = peer, .connection = 21});
        return 21u;
    };
    f.readTCP = [](uint32_t h, void *ctx, MPPacketSink sink) {
        auto &q = tcpQueue[h];
        while (!q.empty()) {
            auto b = std::move(q.front());
            q.pop_front();
            sink(ctx, peer + h, b.data(), int(b.size()));
        }
    };
    f.sendTCP = [](uint32_t h, const void *b, int32_t n) {
        auto frame = multiplex::decodeFrame({static_cast<const std::byte *>(b), size_t(n)});
        if (!frame) {
            ++errors;
            return 1;
        }
        if (h == 21) {
            if (frame->type == multiplex::PacketType::Disconnect) {
                ++guestClose;
                return 1;
            }
            check(frame->payload.size() <= 1100);
            guestBytes += int(frame->payload.size());
            tcpQueue[h].push_back(multiplex::encodeFrame(frame->connectionId, frame->type, frame->payload));
            return 1;
        }
        if (frame->type == multiplex::PacketType::Data) {
            check(frame->connectionId.view() == "aB12z9" && frame->payload.size() == 3 &&
                  frame->payload[0] == std::byte(h) && frame->payload[2] == std::byte{0xa5});
            ++tcpReturned;
        }
        return 1;
    };
    f.connectionPing = [](uint32_t, bool *r) {
        *r = false;
        return 8;
    };
    f.vpnPing = [](uint64_t, bool *r) {
        *r = true;
        return 12;
    };
    f.acceptVPN = [](uint64_t) { return true; };
    f.closeVPN = [](uint64_t p) { check(p == peer); };
    f.sendVPN = [](uint64_t p, const void *b, int32_t n, bool reliable, bool restart) {
        check(p == peer);
        auto decoded = wire::decodeEnvelope({static_cast<const std::byte *>(b), size_t(n)});
        if (!decoded) {
            ++errors;
            return false;
        }
        check(reliable == (decoded->type != VPN::IpPacket));
        check(restart == (decoded->type == VPN::SessionHello));
        if (decoded->type == VPN::SessionHello) {
            originalNegotiator.initialize(domain::PeerId{peer}, 0x0a000000, 0xff000000);
            auto queue = [](VPN type, const uint8_t *bytes, size_t n, bool reliable) {
                check(reliable);
                vpnQueue.push_back(*wire::encodeEnvelope(type, std::as_bytes(std::span{bytes, n})));
            };
            originalNegotiator.setSendCallback(
                [queue](VPN type, const uint8_t *b, size_t n, domain::PeerId to, bool reliable) {
                    check(to.value() == me);
                    queue(type, b, n, reliable);
                }, queue);
            originalNegotiator.setSuccessCallback([](uint32_t ip, const NodeID &) { remoteIP = ip; });
            probing = true;
            originalNegotiator.startNegotiation();
        }
        if (decoded->type == VPN::ProbeRequest) {
            auto payload = wire::decodePayload<wire::ProbeRequestPayload>(decoded->payload);
            check(payload.has_value());
            if (payload)
                originalNegotiator.handleProbeRequest(*payload, domain::PeerId{me});
        }
        if (decoded->type == VPN::AddressAnnounce) {
            auto payload = wire::decodePayload<wire::AddressAnnouncePayload>(decoded->payload);
            check(payload.has_value());
            if (payload)
                originalNegotiator.handleAddressAnnounce(*payload, domain::PeerId{me}, "Mac");
        }
        if (decoded->type == VPN::IpPacket) {
            auto expected = ipPacket(localIP, remoteIP);
            auto wrapper = wire::decodePayloadPrefix<wire::VpnPacketWrapper>(decoded->payload);
            check(wrapper && wrapper->senderNodeId == NodeIdentity::generate(domain::PeerId{me}) &&
                  ntohl(wrapper->sourceIP) == localIP);
            check(decoded->payload.size() == 36 + expected.size() &&
                  memcmp(decoded->payload.data() + 36, expected.data(), expected.size()) == 0);
            ++ipSent;
            wire::VpnPacketWrapper reply{remoteNode, htonl(remoteIP)};
            auto prefix = wire::asBytes(reply);
            Bytes data(prefix.begin(), prefix.end());
            auto packet = ipPacket(remoteIP, localIP);
            data.insert(data.end(), packet.begin(), packet.end());
            vpnQueue.push_back(*wire::encodeEnvelope(VPN::IpPacket, data));
        }
        return true;
    };
    f.readVPN = [](void *ctx, MPPacketSink sink) {
        while (!vpnQueue.empty()) {
            auto b = std::move(vpnQueue.front());
            vpnQueue.pop_front();
            sink(ctx, peer, b.data(), int(b.size()));
        }
    };
    f.pingLocation = [](char *p, int32_t n) {
        snprintf(p, n, "location");
        return true;
    };
    f.estimatePing = [](const char *) { return 11; };
    f.popList = [](uint32_t *, int32_t) { return 0; };
    f.popPing = [](uint32_t, uint32_t *) { return -1; };
    f.avatar = [](uint64_t, uint8_t *, int32_t) { return 0; };
    f.openTun = [](char *name, int32_t n, char *, int32_t) {
        check(socketpair(AF_UNIX, SOCK_DGRAM, 0, tunPair) == 0);
        nonblock(tunPair[0]);
        nonblock(tunPair[1]);
        snprintf(name, n, "fixture");
        return tunPair[0];
    };
    f.configureTun = [](const char *name, const char *ip, char *, int32_t) {
        check(std::string(name) == "fixture" && tunMode);
        localIP = ntohl(inet_addr(ip));
        check((localIP >> 24) == 10);
        return true;
    };
    return &f;
}
