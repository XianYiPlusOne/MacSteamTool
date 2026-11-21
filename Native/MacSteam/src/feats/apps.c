// Ownership spoofing
#include "apps.h"
#include "../config/config.h"
#include "../constants.h"
#include "../util/log.h"
#include <string.h>

static int g_applist_requested = 0;

void sx_apps_force_ready(void) {
    if (!g_applist_requested) {
        g_applist_requested = 1;
        SX_LOG("ownership spoofing force-enabled (late injection)");
    }
}

int sx_apps_spoof_ownership(uint32_t appId, int origResult,
                            AppOwnershipInfo_t *info, uint32_t ownerAccountId) {
    sx_config_t *g_cfg = sx_config_current;

    if (!g_cfg || !sx_config_has_app(g_cfg, (int)appId))
        return origResult;

    if (!g_applist_requested)
        return origResult;

    SX_LOG_ONCE_KEY(appId, "CheckAppOwnership: SPOOFING appid %u (orig=%d, acctId=%u)",
                    appId, origResult, ownerAccountId);

    if (info) {
        info->subId = g_cfg->pkg_count > 0 ? g_cfg->package_ids[0] : 0;
        info->releaseState = RELEASE_STATE_RELEASED;
        info->owner = ownerAccountId ? ownerAccountId : 1;
        info->purchaseTime = FAKE_PURCHASE_TIME;
        info->ownsLicense = 1;
    }

    return 1;
}

int sx_apps_is_owned_for_depot(uint32_t depotId, uint32_t depotCtxAppId, int origResult) {
    sx_config_t *g_cfg = sx_config_current;

    if (origResult || !g_cfg)
        return origResult;

    if (!g_applist_requested)
        return origResult;

    // BuildDepotDependency passes the depot ID in x1, not the owning AppID.
    // A base depot (1601582) need not appear in Apps (1601580), while a DLC
    // depot can coincidentally share its AppID (2791490). Checking only Apps
    // therefore kept the artbook but dropped Frostpunk 2's game content.
    int selected = sx_config_has_app(g_cfg, (int)depotId);
    if (!selected && sx_config_has_app(g_cfg, (int)depotCtxAppId)) {
        for (int i = 0; i < g_cfg->dk_count && !selected; ++i) {
            // DLC depots are grouped under their owning DLC, not the base app.
            if (!sx_config_has_app(g_cfg, g_cfg->depot_keys[i].app_id)) continue;
            for (int j = 0; j < g_cfg->depot_keys[i].depot_count; ++j) {
                if (g_cfg->depot_keys[i].depots[j].depot_id == (int)depotId) {
                    selected = 1;
                    break;
                }
            }
        }
    }
    if (!selected) return origResult;

    SX_LOG_ONCE_KEY(depotId, "BIsAppOwnedForDepot: selected depot %u (app=%u, orig=%d)",
                    depotId, depotCtxAppId, origResult);
    return 1;
}

uint32_t sx_apps_inject_subscribed(uint32_t *appids, uint32_t max_apps, uint32_t count) {
    sx_config_t *g_cfg = sx_config_current;
    if (!g_cfg || g_cfg->app_count == 0) return count;

    int to_inject = 0;
    for (int i = 0; i < g_cfg->app_count; i++) {
        uint32_t app = (uint32_t)g_cfg->app_ids[i];
        int found = 0;
        if (appids) {
            for (uint32_t j = 0; j < count && j < max_apps; j++) {
                if (appids[j] == app) { found = 1; break; }
            }
        }
        if (!found) to_inject++;
    }

    if (max_apps == 0 || !appids) {
        SX_LOG_ONCE_KEY(count + (uint32_t)to_inject,
                        "GetSubscribedApps: size query -> %u + %d = %u", count, to_inject, count + to_inject);
        return count + (uint32_t)to_inject;
    }

    if (count > max_apps)
        count = max_apps;

    for (int i = 0; i < g_cfg->app_count; i++) {
        uint32_t app = (uint32_t)g_cfg->app_ids[i];
        int found = 0;
        for (uint32_t j = 0; j < count; j++) {
            if (appids[j] == app) { found = 1; break; }
        }
        if (!found && count < max_apps) {
            appids[count] = app;
            count++;
            SX_LOG_ONCE_KEY(app, "GetSubscribedApps: injected appid %u (now %u total)", app, count);
        }
    }

    if (!g_applist_requested) {
        g_applist_requested = 1;
        SX_LOG("GetSubscribedApps: applist populated, ownership spoofing enabled");
    }

    return count;
}

int sx_apps_is_subscribed(uint32_t appId, int origResult) {
    sx_config_t *g_cfg = sx_config_current;

    if (origResult || !g_cfg || !sx_config_has_app(g_cfg, (int)appId))
        return origResult;

    SX_LOG_ONCE_KEY(appId, "BIsSubscribedApp: SPOOFING subscribed for appid %u (orig=%d)",
                    appId, origResult);
    return 1;
}
