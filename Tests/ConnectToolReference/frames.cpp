// Test-only oracle. These calls go through the pinned upstream 1.6.0 codecs.
#include "network/protocol/multiplex_protocol.h"
#include "network/protocol/wire_codec.h"
#include "network/vpn/node_identity.h"
#ifdef _WIN32
#include <winsock2.h>
#else
#include <arpa/inet.h>
#endif
#include <iostream>
#include <map>
#include <sstream>

using Bytes = std::vector<std::byte>;
using namespace connecttool;
using namespace connecttool::wire;
std::string hex(std::span<const std::byte> bytes) {
    constexpr char digits[] = "0123456789abcdef";
    std::string out;
    for (auto b : bytes) {
        auto n = std::to_integer<uint8_t>(b);
        out += digits[n >> 4];
        out += digits[n & 15];
    }
    return out;
}
int main(int argc, char **) {
    const uint64_t peer = 76561198012345678ULL;
    const uint32_t ip = htonl(0x0a010203);
    const int64_t stamp = 0x0102030405060708;
    auto node = NodeIdentity::generate(domain::PeerId{peer});
    std::map<std::string, Bytes> expected;
    auto add = [&](std::string name, wire::VpnMessageType type, auto bytes) {
        expected[name] = *encodeEnvelope(type, bytes);
    };
    using T = wire::VpnMessageType;
    add("probe", T::ProbeRequest, asBytes(ProbeRequestPayload{ip, node}));
    add("conflict", T::ProbeResponse, asBytes(ProbeResponsePayload{ip, node, stamp}));
    add("announce", T::AddressAnnounce, asBytes(AddressAnnouncePayload{ip, node}));
    add("release", T::ForcedRelease, asBytes(ForcedReleasePayload{ip, node}));
    add("heartbeat", T::Heartbeat, asBytes(HeartbeatPayload{ip, node, stamp}));
    add("ack", T::HeartbeatAck, std::span<const std::byte>{});
    add("hello", T::SessionHello, std::span<const std::byte>{});
    Bytes route(12);
    memcpy(route.data(), &peer, 8);
    memcpy(route.data() + 8, &ip, 4);
    add("route", T::RouteUpdate, route);
    VpnPacketWrapper wrapper{node, ip};
    Bytes packet(asBytes(wrapper).begin(), asBytes(wrapper).end());
    const uint8_t ipv4[] = {0x45, 0, 0, 20, 0, 1, 0, 0, 64, 17, 0, 0, 10, 1, 2, 3, 255, 255, 255, 255};
    for (auto b : ipv4)
        packet.push_back(std::byte{b});
    add("ip", T::IpPacket, packet);
    auto id = *multiplex::ConnectionId::parse("aB12z9");
    expected["tcp"] = multiplex::encodeFrame(id, multiplex::PacketType::Data, route);
    expected["close"] = multiplex::encodeFrame(id, multiplex::PacketType::Disconnect, route);
    expected["empty"] = multiplex::encodeFrame(id, multiplex::PacketType::Data);
    if (argc == 1) {
        for (auto &[key, value] : expected)
            std::cout << key << " " << hex(value) << "\n";
        return 0;
    }
    std::string name, value;
    while (std::cin >> name >> value) {
        if (!expected.contains(name) || value != hex(expected.at(name)))
            return 1;
        Bytes incoming;
        for (size_t i = 0; i < value.size(); i += 2)
            incoming.push_back(std::byte(std::stoi(value.substr(i, 2), nullptr, 16)));
        if (name == "tcp" || name == "close" || name == "empty") {
            auto frame = multiplex::decodeFrame(incoming);
            if (!frame || frame->connectionId.view() != "aB12z9")
                return 2;
        } else if (!decodeEnvelope(incoming))
            return 3;
        expected.erase(name);
    }
    return expected.empty() ? 0 : 4;
}
