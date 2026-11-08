#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FSContext FSContext;
FSContext *fs_create(const char *library, uint32_t app);
FSContext *fs_create_session(const char *library, uint32_t app, int load_stats);
int fs_schema(FSContext *context, uint64_t public_user);
int fs_tickets(FSContext *context, void *ownership, uint32_t capacity, uint32_t *ownership_size, void *encrypted, uint32_t encrypted_capacity, uint32_t *encrypted_size);
const char *fs_error(FSContext *context);
int fs_ready(FSContext *context);
uint32_t fs_account(FSContext *context);
int fs_refresh(FSContext *context);
uint32_t fs_count(FSContext *context);
const char *fs_name(FSContext *context, uint32_t index);
const char *fs_attribute(FSContext *context, const char *name, const char *attribute);
int fs_get(FSContext *context, const char *name, uint32_t *timestamp);
int fs_set(FSContext *context, const char *name, int achieved);
int fs_store(FSContext *context);
void fs_destroy(FSContext *context);
#ifdef __cplusplus
}
#endif
