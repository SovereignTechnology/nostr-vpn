#!/bin/bash
# Overlapping-LAN check for nostr-vpn mobile routes (mmalmi/nostr-vpn #158 item 3),
# run from a computer with adb against a test phone.
#
# Setup:
# - Join the phone to a Wi-Fi network numbered inside 10.44.0.0/16 whose gateway
#   and DNS server is $GATEWAY (default 10.44.0.1). We used a Linux
#   NetworkManager shared-mode access point with 10.44.0.1/24.
# - Install the "before" and "after" debug APKs from this branch's workflow
#   (proof=android); they use the package names $PREFIX.before / $PREFIX.after.
# - Unlock the phone. Set ANDROID_SERIAL if more than one device is attached.
#
#   android-overlap.sh <before|after>
#
# Never tap the system VPN consent dialog for these runs: on the Android 17 test
# phone, granting it also set the app as the Always-on VPN with "Block
# connections without VPN", which cut off the whole phone whenever the test VPN
# stopped and confounded the checks. The script pre-consents through appops.
set -u
VARIANT=${1:?usage: android-overlap.sh before|after}
PREFIX=${NVPN_TEST_PACKAGE_PREFIX:-org.sovtech.nvpntest}
GATEWAY=${NVPN_TEST_GATEWAY:-10.44.0.1}
# adb shell runs its arguments through the phone's shell: accept only plain values.
case "$VARIANT" in before | after) ;; *) echo "usage: android-overlap.sh before|after" >&2; exit 2 ;; esac
[[ "$PREFIX" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]] || { echo "bad package prefix" >&2; exit 2; }
[[ "$GATEWAY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "bad gateway address" >&2; exit 2; }
PKG=$PREFIX.$VARIANT
ACTIVITY=$PKG/org.nostrvpn.app.MainActivity
EXTRA=fi.siriusbusiness.nvpn   # debug-extra prefix is fixed in AndroidDebugAutomation.kt

a() { adb "$@"; }
debug_action() { a shell am start -n "$ACTIVITY" --es "$EXTRA.DEBUG_ACTION" "$@" >/dev/null 2>&1; }

lockdown_state() { # <always-on package>/<lockdown flag>
  echo "$(a shell settings get secure always_on_vpn_app | tr -d '\r')/$(a shell settings get secure always_on_vpn_lockdown | tr -d '\r')"
}

refuse_consent_dialog() {
  a shell uiautomator dump /sdcard/nvpn-overlap-ui.xml >/dev/null 2>&1
  if a shell cat /sdcard/nvpn-overlap-ui.xml 2>/dev/null | grep -q 'package="com.android.vpndialogs"'; then
    a shell input keyevent KEYCODE_BACK
    echo "VPN consent dialog appeared despite appops pre-consent; dismissed it without granting"
    exit 1
  fi
}

vpn_ipv4_routes() { # IPv4 routes of the test app's own VPN network (found by package; it may be tun0)
  a shell dumpsys connectivity 2>/dev/null | tr -d '\r' | awk -v pkg="VPN:$PKG}" '
    /^ *NetworkAgentInfo\{/ { vpn = (index($0, pkg) > 0); iface = "" }
    vpn && match($0, /InterfaceName: [a-z0-9]+/) { iface = substr($0, RSTART + 15, RLENGTH - 15) }
    vpn && iface != "" && /Routes: \[/ {
      line = $0; sub(/.*Routes: \[/, "", line); sub(/\].*/, "", line)
      n = split(line, parts, ",")
      for (i = 1; i <= n; i++) if (parts[i] ~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+ ->/) {
        sub(/^ +/, "", parts[i]); print iface ": " parts[i] } }'
}

require_unlocked() {
  a shell input keyevent KEYCODE_WAKEUP
  sleep 1
  if a shell dumpsys window 2>/dev/null | grep -q 'isKeyguardShowing=true'; then
    echo "phone is locked: unlock it and keep the screen on"
    exit 2
  fi
}

require_no_always_on() {
  local state
  state=$(lockdown_state)
  echo "always-on/lockdown $1: $state"
  case "$state" in null/0 | /0) ;; *)
    echo "an Always-on VPN is set; turn it off in Android VPN settings first"
    debug_action disconnect
    exit 1 ;;
  esac
}

probe() {
  a shell "ping -c 2 -W 2 $GATEWAY >/dev/null 2>&1 && g=reachable || g=UNREACHABLE
           ping -c 1 -W 3 github.com >/dev/null 2>&1 && d=ok || d=FAILED
           echo \"gateway $GATEWAY: \$g | DNS+internet (github.com): \$d\""
}

echo "== $PKG ($(a shell dumpsys package "$PKG" | grep -m1 -oE 'versionName=[^ ]+' | tr -d '\r'))"
echo "android $(a shell getprop ro.build.version.release | tr -d '\r'), $(a shell getprop ro.product.model | tr -d '\r')"
require_unlocked
echo "phone wifi: $(a shell cmd wifi status 2>/dev/null | grep -oE 'SSID: "[^"]+"' | head -1)"
for other in before after; do
  [ "$other" = "$VARIANT" ] || a shell am force-stop "$PREFIX.$other" >/dev/null 2>&1
done
a shell appops set "$PKG" ACTIVATE_VPN allow
require_no_always_on "before connect"
debug_action disconnect
sleep 2
debug_action add_network --es "$EXTRA.DEBUG_NETWORK_NAME" "overlap-$VARIANT"
sleep 4
debug_action connect
sleep 3
refuse_consent_dialog
routes=""
for _ in $(seq 1 30); do
  routes=$(vpn_ipv4_routes)
  [ -n "$routes" ] && break
  sleep 2
done
if [ -z "$routes" ]; then
  echo "test VPN did not come up; VPN networks now:"
  a shell dumpsys connectivity 2>/dev/null | tr -d '\r' | grep -E '^ *NetworkAgentInfo\{.*VPN' | cut -c1-200
  exit 1
fi
require_no_always_on "with the test VPN up"
echo "-- test VPN link"
a shell dumpsys connectivity 2>/dev/null | tr -d '\r' | grep -A3 "extra: VPN:$PKG}" \
  | grep -oE 'InterfaceName: [a-z0-9]+|LinkAddresses: \[[^]]*\]|DnsAddresses: \[[^]]*\]' | sed 's/^/   /'
echo "-- test VPN IPv4 routes"
echo "$routes" | sed 's/^/   /'
echo "-- checks with the test VPN on (3 rounds)"
for _ in 1 2 3; do probe; sleep 2; done | sort | uniq -c
debug_action disconnect
sleep 4
echo "-- after disconnect"
probe
a shell appops set "$PKG" ACTIVATE_VPN default
a shell rm -f /sdcard/nvpn-overlap-ui.xml
