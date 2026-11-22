#pragma once
#include <stdbool.h>
#include <stdint.h>

enum MPEventKind {
    MP_CREATED = 1,
    MP_ENTERED,
    MP_LIST,
    MP_CHANGED,
    MP_CHAT,
    MP_INVITED,
    MP_CONNECTION,
    MP_REQUEST,
    MP_SESSION_FAILED,
    MP_KICKED,
    MP_STEAM_LOST
};
typedef struct {
    int32_t kind, value;
    uint64_t call, lobby, peer;
    uint32_t connection, listener;
} MPEvent;
typedef void (*MPEventSink)(void *, MPEvent, const void *, int32_t);
typedef void (*MPPacketSink)(void *, uint64_t, const void *, int32_t);
typedef struct {
    bool (*start)(char *, int32_t);
    void (*stop)(void);
    void (*poll)(void *, MPEventSink);
    uint64_t (*user)(void);
    const char *(*name)(uint64_t);
    uint64_t (*create)(int32_t);
    uint64_t (*join)(uint64_t);
    void (*leave)(uint64_t);
    uint64_t (*owner)(uint64_t);
    int32_t (*memberCount)(uint64_t);
    uint64_t (*member)(uint64_t, int32_t);
    const char *(*metadata)(uint64_t, const char *);
    bool (*setMetadata)(uint64_t, const char *, const char *);
    bool (*chat)(uint64_t, const void *, int32_t);
    bool (*invite)(uint64_t, uint64_t);
    uint64_t (*list)(const char *, const char *);
    uint64_t (*listedLobby)(int32_t);
    int32_t (*friendCount)(void);
    uint64_t (*friendAt)(int32_t);
    int32_t (*personaState)(uint64_t);
    bool (*isFriend)(uint64_t);
    const char *(*presence)(uint64_t, const char *);
    bool (*setPresence)(const char *, const char *);
    uint32_t (*listen)(void);
    void (*closeListen)(uint32_t);
    uint32_t (*connect)(uint64_t, bool);
    bool (*accept)(uint32_t);
    void (*closeTCP)(uint32_t);
    int32_t (*sendTCP)(uint32_t, const void *, int32_t);
    void (*readTCP)(uint32_t, void *, MPPacketSink);
    bool (*acceptVPN)(uint64_t);
    void (*closeVPN)(uint64_t);
    bool (*sendVPN)(uint64_t, const void *, int32_t, bool, bool);
    void (*readVPN)(void *, MPPacketSink);
    int32_t (*connectionPing)(uint32_t, bool *);
    int32_t (*vpnPing)(uint64_t, bool *);
    bool (*pingLocation)(char *, int32_t);
    int32_t (*estimatePing)(const char *);
    int32_t (*popList)(uint32_t *, int32_t);
    int32_t (*popPing)(uint32_t, uint32_t *);
    int32_t (*avatar)(uint64_t, uint8_t *, int32_t);
    int32_t (*openTun)(char *, int32_t, char *, int32_t);
    bool (*configureTun)(const char *, const char *, char *, int32_t);
} MPFunctions;
