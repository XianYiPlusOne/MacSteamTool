#!/bin/sh
# Shared by the CrossOver and MacSteamTool Wine launchers.
controller_ids() {
  printf '%s\n' "$1" | tr ',' '\n' | tr 'A-F' 'a-f' \
    | sed -n 's/^[[:space:]]*0x\([0-9a-f]\{4\}\)\/0x\([0-9a-f]\{4\}\)[[:space:]]*$/\1\/\2/p' \
    | sort -u
}

ids_without() {
  printf '%s\n' "$2" -- "$1" \
    | awk '$0 == "--" { s = 1; next } !s { b[$0]; next } $0 != "" && !($0 in b)'
}

hidraw_lines() {
  printf '%s\n' "$2" | while read -r id; do
    [ -n "$id" ] || continue
    if [ "$1" = add ]; then
      printf '%s\r\n' "[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\$id]" \
        '"Hidraw"=dword:00000000' ''
    else
      printf '%s\r\n' "[-HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\$id]" ''
    fi
  done
}

write_owned_controllers() {
  if printf '%s\n' "$1" | sed '/^$/d' | sort -u > "$controllers_file.new" \
    && mv -f "$controllers_file.new" "$controllers_file"; then
    return 0
  fi
  rm -f "$controllers_file.new"
  return 1
}

# Proton hides the controllers that Steam Input handles from the Wine process. CrossOver
# still reads a few directly (DualSense, DualShock 4, Switch 1 Pro Controller and Joy-Cons),
# so Hidraw=0 hides those too. The Switch controllers get Hidraw=0 even when Steam Input
# is off, to avoid silently breaking controller support in most games.
plan_hidden_controllers() {
  controllers_file="$STEAM_COMPAT_DATA_PATH/notproton-hidden-controllers"
  controllers_add=""
  controllers_remove=""
  controllers_wanted=""
  [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ ! -L "$controllers_file" ] || return 1
  owned=""
  [ ! -f "$controllers_file" ] || owned=$(sed -n '/^[0-9a-f]\{4\}\/[0-9a-f]\{4\}$/p' "$controllers_file")
  in_registry=""
  [ ! -f "$WINEPREFIX/system.reg" ] || in_registry=$(LC_ALL=C awk '
    /^\[/ {
      line = tolower($0)
      prefix = "[system\\\\controlset001\\\\services\\\\winebus\\\\devices\\\\"
      if (index(line, prefix) != 1) next
      id = substr(line, length(prefix) + 1, 9)
      if (id ~ /^[0-9a-f]{4}\/[0-9a-f]{4}$/ && substr(line, length(prefix) + 10, 1) == "]") print id
    }' "$WINEPREFIX/system.reg" \
    | sort -u)
  if [ "$NOTPROTON_RAW_CONTROLLERS" != "1" ]; then
    controllers_wanted=$(ids_without "$(controller_ids "$SDL_GAMECONTROLLER_IGNORE_DEVICES")" \
      "$(controller_ids "$SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT")")
    controllers_wanted=$(printf '%s\n' "$controllers_wanted" 057e/2006 057e/2007 057e/2009 | sed '/^$/d' | sort -u)
    # Steam sends install scripts no ignore list. Keep the game's hidden controllers instead of clearing them.
    if [ "$verb" = run ]; then
      controllers_wanted=$(printf '%s\n' "$controllers_wanted" "$owned" | sed '/^$/d' | sort -u)
    fi
    controllers_wanted=$(ids_without "$controllers_wanted" "$(ids_without "$in_registry" "$owned")")
  fi
  controllers_add=$(ids_without "$controllers_wanted" "$in_registry")
  controllers_remove=$(ids_without "$owned" "$controllers_wanted")
  write_owned_controllers "$owned
$controllers_wanted"
}

# Sets Wine's DisableHidraw for games with "Disable hidraw" checked. When it's
# unchecked, the value is removed only if NotProton set it.
plan_disable_hidraw() {
  hidraw_file="$STEAM_COMPAT_DATA_PATH/notproton-disable-hidraw"
  hidraw_value=""
  [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ ! -L "$hidraw_file" ] || return 1
  hidraw_set=""
  [ ! -f "$WINEPREFIX/system.reg" ] || hidraw_set=$(LC_ALL=C awk '
      /^\[/ { s = index(tolower($0), "[system\\\\controlset001\\\\services\\\\winebus]") == 1; next }
      s && tolower($0) == "\"disablehidraw\"=dword:00000001" { print 1; exit }' "$WINEPREFIX/system.reg")
  if [ "$NOTPROTON_DISABLE_HIDRAW" = "1" ]; then
    [ -n "$hidraw_set" ] || hidraw_value='"DisableHidraw"=dword:00000001'
  elif [ -f "$hidraw_file" ] && [ -n "$hidraw_set" ]; then
    hidraw_value='"DisableHidraw"=-'
  fi
}

winebus_lines() {
  [ -n "$hidraw_value" ] || return 0
  printf '%s\r\n' '[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus]' "$hidraw_value" ''
}

# High Resolution doubles LogPixels and turning it off halves it
plan_logpixels() {
  dpi_value=""
  new_dpi=""
  dpi_registry=/dev/null
  [ ! -f "$WINEPREFIX/user.reg" ] || dpi_registry="$WINEPREFIX/user.reg"
  read -r retina_was dpi <<EOF
$(LC_ALL=C awk '
  /^\[/ { s = 0
    line = tolower($0)
    if (index(line, "[software\\\\wine\\\\mac driver]") == 1) s = 1
    else if (index(line, "[control panel\\\\desktop]") == 1) s = 2
    next }
  s { $0 = tolower($0) }
  s == 1 && $0 ~ /^"retinamode"="[yt1]/ { r = 1 }
  s == 2 && $0 ~ /^"logpixels"=dword:[0-9a-f]+$/ && length($0) <= 26 { d = substr($0, 19) }
  END { print r + 0, d }' "$dpi_registry")
EOF
  [ -n "$dpi" ] || [ ! -f "$WINEPREFIX/system.reg" ] || dpi=$(LC_ALL=C awk '
      /^\[/ { s = index(tolower($0), "[system\\\\controlset001\\\\hardware profiles\\\\current\\\\software\\\\fonts]") == 1; next }
      s { $0 = tolower($0) }
      s && $0 ~ /^"logpixels"=dword:[0-9a-f]+$/ && length($0) <= 26 { print substr($0, 19); exit }' "$WINEPREFIX/system.reg")
  dpi=$((0x${dpi:-0}))
  [ "$dpi" -gt 0 ] || dpi=96
  if [ "$NOTPROTON_RETINA" = "1" ]; then
    [ "$retina_was" = 1 ] && [ "$dpi" -ge 110 ] || [ "$dpi" -gt 2147483647 ] || new_dpi=$((dpi * 2))
  elif [ "$retina_was" = 1 ]; then
    new_dpi=$((dpi / 2))
    [ "$new_dpi" -ge 96 ] || new_dpi=96
  fi
  [ -z "$new_dpi" ] || [ "$new_dpi" -eq "$dpi" ] || dpi_value=$(printf '"LogPixels"=dword:%08x' "$new_dpi")
}

video_lines() {
  [ "$verb" = waitforexitandrun ] || return 0
  printf '%s\r\n' '[HKEY_CURRENT_USER\Software\Wine\Mac Driver]' "$retina_line" ''
  [ -n "$dpi_value" ] || return 0
  printf '%s\r\n' '[HKEY_CURRENT_USER\Control Panel\Desktop]' "$dpi_value" ''
}

prefix_up_to_date() {
  [ -r "$WINEPREFIX/.update-timestamp" ] || return 1
  read -r stamp _ < "$WINEPREFIX/.update-timestamp" || return 1
  stamp=${stamp%"$(printf '\r')"}
  case "$stamp" in '' | *[!0-9]*) return 1 ;; esac
  [ "$stamp" = "$(stat -f %m "$CX_ROOT/share/wine/wine.inf" 2>/dev/null)" ]
}

# Proton only writes the registry when its prefix version changes.
settings_already_applied() {
  prefix_up_to_date || return 1
  [ -f "$WINEPREFIX/system.reg" ] && [ -f "$WINEPREFIX/user.reg" ] || return 1
  LC_ALL=C awk '
    function double(s,   out, i) {
      out = ""
      while ((i = index(s, "\\")) > 0) { out = out substr(s, 1, i) "\\"; s = substr(s, i + 1) }
      return out s
    }
    FNR == 1 {
      file++
      root = file == 2 ? "hkey_local_machine\\" : "hkey_current_user\\"
      key = ""
    }
    { sub(/\r$/, "") }
    /^\[/ {
      key = ""
      end = index($0, "]")
      if (!end) { if (file == 1) bad = 1; next }
      name = tolower(substr($0, 2, end - 2))
      if (file == 1) {
        deleted = sub(/^-/, "", name)
        ccs = "hkey_local_machine\\system\\currentcontrolset\\"
        if (index(name, ccs) == 1)
          name = "hkey_local_machine\\system\\controlset001\\" substr(name, length(ccs) + 1)
        split(name, part, "\\")
        name = substr(name, 1, length(part[1]) + 1) double(substr(name, length(part[1]) + 2))
        if (deleted) gone[name] = 1
        else { key = name; wanted[name] = 1 }
        next
      }
      name = root name
      for (g in gone) if (name == g || index(name, g "\\\\") == 1) bad = 1
      if (name in wanted) key = name
      next
    }
    key == "" || !match($0, /^("([^"\\]|\\.)*"|@)=/) { next }
    {
      name = tolower(substr($0, 1, RLENGTH - 1))
      value = substr($0, RLENGTH + 1)
      if (file == 1) want[key, name] = value
      else have[key, name] = value
    }
    END {
      if (file != 3) exit 1
      for (kv in want) {
        if (want[kv] == "-") { if (kv in have) bad = 1 }
        else if (!(kv in have) || have[kv] != want[kv]) bad = 1
      }
      exit bad
    }
  ' "$settings_file" "$WINEPREFIX/system.reg" "$WINEPREFIX/user.reg"
}

import_prefix_settings() {
  if [ "$NOTPROTON_RETINA" = "1" ]; then
    retina_line='"RetinaMode"="y"'
  else
    retina_line='"RetinaMode"=-'
  fi
  dpi_value=""
  controllers_planned=0
  if plan_hidden_controllers 2>/dev/null; then
    controllers_planned=1
  else
    controllers_add=""
    controllers_remove=""
    echo "=== could not track the hidden controllers, leaving them as they are ===" >> "$log" 2>&1 || true
  fi
  hidraw_planned=0
  if plan_disable_hidraw 2>/dev/null; then
    hidraw_planned=1
    if [ "$NOTPROTON_DISABLE_HIDRAW" = "1" ] && [ -n "$hidraw_value" ]; then
      : > "$hidraw_file" 2>/dev/null || hidraw_value=""
    fi
  else
    hidraw_value=""
    echo "=== could not track DisableHidraw, leaving it as it is ===" >> "$log" 2>&1 || true
  fi
  # Steam sends install scripts no launch options, so they keep the game's video settings.
  if [ "$verb" = waitforexitandrun ]; then
    plan_logpixels 2>/dev/null || dpi_value=""
  fi
  settings_file=$(mktemp "$WINEPREFIX/drive_c/notproton-settings.XXXXXX" 2>/dev/null) \
    || settings_file=""
  if [ -z "$settings_file" ] || ! { printf '%s\r\n' \
      'Windows Registry Editor Version 5.00' '' \
      '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
      '[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
      '[HKEY_CURRENT_USER\Software\Wine\WineDbg]' '"ShowCrashDialog"=dword:00000000' '' \
      && video_lines && printf '%s\r\n' \
      '[HKEY_LOCAL_MACHINE\Software\Classes\steam]' '"URL Protocol"=""' '' \
      '[HKEY_LOCAL_MACHINE\Software\Classes\steam\shell\open\command]' \
      '@="\"C:\\Program Files (x86)\\Steam\\steam.exe\" \"%1\""' '' \
      && hidraw_lines add "$controllers_add" && hidraw_lines remove "$controllers_remove" \
      && winebus_lines; } \
      > "$settings_file" 2>/dev/null; then
    [ -z "$settings_file" ] || rm -f "$settings_file"
    echo "=== could not write the prefix settings, launching without them ===" >> "$log" 2>&1 || true
    # the bridge staging still needs a built prefix
    without_lock_fds "$WINELOADER" wineboot --init >> "$log" 2>&1 || true
    return 0
  fi
  if settings_already_applied; then
    import_status=0
    echo "=== prefix settings already applied, skipped the import ===" >> "$log" 2>&1 || true
  else
    without_lock_fds "$WINELOADER" reg import "C:\\${settings_file##*/}" >> "$log" 2>&1 \
      && import_status=0 || import_status=$?
  fi
  rm -f "$settings_file"
  if [ "$import_status" -eq 0 ] && [ "$hidraw_planned" -eq 1 ] && [ "$NOTPROTON_DISABLE_HIDRAW" != "1" ]; then
    rm -f "$hidraw_file"
  fi
  if [ "$import_status" -eq 0 ] && [ -n "$controllers_add$controllers_remove$hidraw_value$dpi_value" ]; then
    # Wine only reads these keys when it starts, so restart Wine to apply them.
    without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
    without_lock_fds "$WINESERVER" -w >> "$log" 2>&1 || true
  fi
  if [ "$import_status" -eq 0 ] && [ "$hidraw_planned" -eq 1 ] && [ "$NOTPROTON_DISABLE_HIDRAW" = "1" ]; then
    echo "controllers: hidraw disabled (NOTPROTON_DISABLE_HIDRAW=1)" >> "$log" 2>&1 || true
  fi
  if [ "$import_status" -eq 0 ] && [ -n "$dpi_value" ]; then
    echo "video: LogPixels=$new_dpi" >> "$log" 2>&1 || true
  fi
  if [ "$import_status" -eq 0 ] && [ "$controllers_planned" -eq 1 ]; then
    write_owned_controllers "$controllers_wanted" 2>/dev/null || true
    if [ "$NOTPROTON_RAW_CONTROLLERS" = "1" ]; then
      echo "controllers: games read them directly (NOTPROTON_RAW_CONTROLLERS=1)" >> "$log" 2>&1 || true
    elif [ -n "$controllers_wanted" ]; then
      echo "controllers: $(printf '%s\n' "$controllers_wanted" | grep -c .) kept off hidraw" \
        >> "$log" 2>&1 || true
    fi
  fi
  [ "$import_status" -eq 0 ] \
    || echo "=== prefix settings import exited status=$import_status ===" >> "$log" 2>&1 || true
}
