"""Reject an inert native runtime even if its receipt and signature are valid."""
import subprocess


def validate_macsteam(library, arch="arm64"):
    result = subprocess.run(
        ["nm", "-arch", arch, "-g", "-U", str(library)],
        check=True, capture_output=True, text=True,
    )
    symbols = {line.split()[-1] for line in result.stdout.splitlines() if line.split()}
    required = {
        "_macsteam_version", "_sx_hooks_install_all", "_sx_config_load",
        "_sx_apps_spoof_ownership", "_sx_apps_inject_subscribed",
        "_sx_hot_refresh_start", "_sx_hot_refresh_poll",
        "_sx_reconcile_fire_library_refresh",
    }
    missing = sorted(required - symbols)
    if missing:
        raise RuntimeError(f"{library}: incomplete {arch} macSteam runtime: {', '.join(missing)}")
