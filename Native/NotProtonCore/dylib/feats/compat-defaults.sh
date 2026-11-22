#!/bin/sh
# Shared by the CrossOver and MacSteamTool Wine launchers.
# Helpers launched by Steam or MacSteamTool should inherit the last game session.
# Persist only portable preferences. Runner paths must be rebuilt after upgrades.
session_keys="CX_GRAPHICS_BACKEND D3DM_ENABLE_METALFX DXMT_ENABLE_NVEXT DXMT_METALFX_SPATIAL_SWAPCHAIN DXMT_CONFIG MTL_HUD_ENABLED ROSETTA_ADVERTISE_AVX WINEMSYNC NOTPROTON_RETINA NOTPROTON_RAW_CONTROLLERS NOTPROTON_DISABLE_HIDRAW FEX_X87REDUCEDPRECISION"
remember_compat_settings() (
  [ "$verb" = waitforexitandrun ] && [ -d "${STEAM_COMPAT_DATA_PATH-}" ] || exit 0
  file="$STEAM_COMPAT_DATA_PATH/notproton-session.env"
  tmp=$(mktemp "$file.XXXXXX") || exit 1
  trap 'rm -f "$tmp"' EXIT
  for key in $session_keys; do
    eval "value=\${$key-}"
    [ "$key" != CX_GRAPHICS_BACKEND ] || value="$1"
    case "$value" in ''|*'
'*) continue ;; esac
    printf '%s=%s\n' "$key" "$value" || exit 1
  done > "$tmp" || exit 1
  mv -f "$tmp" "$file"
)
if [ "$verb" = run ] && [ -n "${STEAM_COMPAT_DATA_PATH-}" ] && [ -f "$STEAM_COMPAT_DATA_PATH/notproton-session.env" ]; then
  while IFS= read -r line; do
    case "$line" in *=*) ;; *) continue ;; esac
    key=${line%%=*}
    case "$key" in ''|*[!A-Z0-9_]*) continue ;; esac
    case " $session_keys " in *" $key "*) ;; *) continue ;; esac
    eval "[ -z \"\${$key+x}\" ]" || continue
    export "${line?}"
  done < "$STEAM_COMPAT_DATA_PATH/notproton-session.env"
fi

np_from_defaults() {
  case " $np_defaulted " in *" $1="*) return 0 ;; esac
  return 1
}
np_defaulted=""
case "${np_flavor-}" in
  fex) np_defaults_runner=fex ;;
  rosetta) np_defaults_runner=rosetta ;;
  *) np_defaults_runner=rosetta; [ "${wine_unix##*/}" != aarch64-unix ] || np_defaults_runner=fex ;;
esac
np_defaults_file="$np_support/defaults-$np_defaults_runner"
if [ -n "${np_build-}" ] && [ -f "$np_support/defaults-override-$np_build-$np_defaults_runner" ]; then
  np_defaults_file="$np_support/defaults-override-$np_build-$np_defaults_runner"
fi
if [ "$verb" = waitforexitandrun ] && [ -f "$np_defaults_file" ] && [ -r "$np_defaults_file" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$line" in
      CX_GRAPHICS_BACKEND=dxmt | CX_GRAPHICS_BACKEND=dxvk | CX_GRAPHICS_BACKEND=wined3d) ;;
      CX_GRAPHICS_BACKEND=d3dmetal | D3DM_ENABLE_METALFX=[01] | ROSETTA_ADVERTISE_AVX=[01])
        [ "${wine_unix##*/}" != aarch64-unix ] || continue ;;
      FEX_X87REDUCEDPRECISION=[01])
        [ "${wine_unix##*/}" = aarch64-unix ] || continue ;;
      MTL_HUD_ENABLED=[01] | DXMT_ENABLE_NVEXT=[01] | DXMT_METALFX_SPATIAL_SWAPCHAIN=[01] | \
      WINEMSYNC=[01] | NOTPROTON_RETINA=[01] | NOTPROTON_RAW_CONTROLLERS=[01] | NOTPROTON_DISABLE_HIDRAW=[01]) ;;
      DXMT_CONFIG=*\;*)
        dxmt_added=""
        old_ifs=$IFS; IFS=";"
        set -f
        for clause in $value; do
          case "$clause" in d3d11.metalSpatialUpscaleFactor=*)
            case "${clause#*=}" in 1.5 | 1.72 | 2.0 | 3.0) ;; *) continue ;; esac
            if ! printf '%s' "${DXMT_CONFIG-}" | tr ';' '\n' \
              | grep -q '^[[:space:]]*d3d11\.metalSpatialUpscaleFactor[[:space:]]*='; then
              export DXMT_CONFIG="${DXMT_CONFIG:+$DXMT_CONFIG;}$clause"
              dxmt_added="${dxmt_added:+$dxmt_added;}$clause"
            fi ;;
          d3d11.preferredMaxFrameRate=*)
            case "${clause#*=}" in 30 | 40 | 60 | 120 | 144) ;; *) continue ;; esac
            if ! printf '%s' "${DXMT_CONFIG-}" | tr ';' '\n' \
              | grep -q '^[[:space:]]*d3d11\.preferredMaxFrameRate[[:space:]]*='; then
              export DXMT_CONFIG="${DXMT_CONFIG:+$DXMT_CONFIG;}$clause"
              dxmt_added="${dxmt_added:+$dxmt_added;}$clause"
            fi ;; esac
        done
        set +f; IFS=$old_ifs
        if [ -n "$dxmt_added" ]; then
          np_defaulted="$np_defaulted${np_defaulted:+ }DXMT_CONFIG=$dxmt_added"
        fi
        continue ;;
      DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=*)
        case "${value#*=}" in 1.5 | 1.72 | 2.0 | 3.0) ;; *) continue ;; esac
        if printf '%s' "${DXMT_CONFIG-}" | tr ';' '\n' \
          | grep -q '^[[:space:]]*d3d11\.metalSpatialUpscaleFactor[[:space:]]*='; then
          continue
        fi
        export DXMT_CONFIG="${DXMT_CONFIG:+$DXMT_CONFIG;}$value"
        np_defaulted="$np_defaulted${np_defaulted:+ }$line"
        continue ;;
      DXMT_CONFIG=d3d11.preferredMaxFrameRate=*)
        case "${value#*d3d11.preferredMaxFrameRate=}" in 30 | 40 | 60 | 120 | 144) ;; *) continue ;; esac
        if printf '%s' "${DXMT_CONFIG-}" | tr ';' '\n' \
          | grep -q '^[[:space:]]*d3d11\.preferredMaxFrameRate[[:space:]]*='; then
          continue
        fi
        export DXMT_CONFIG="${DXMT_CONFIG:+$DXMT_CONFIG;}$value"
        np_defaulted="$np_defaulted${np_defaulted:+ }$line"
        continue ;;
      *) continue ;;
    esac
    eval "[ -z \"\${$key+x}\" ]" || continue
    export "${line?}"
    np_defaulted="$np_defaulted${np_defaulted:+ }$line"
  done < "$np_defaults_file"
fi
