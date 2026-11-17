#!/system/bin/sh

# This is the long-lived workload supervised by NEMESIS. It prepares the
# disabled stock PAN profile, starts the APK controller, and periodically
# restores either service if Android kills it. Its output is the NEMESIS
# service log. A filtered logcat child feeds APK and Bluetooth diagnostics into
# that same log; the supervisor loop remains the managed workload.

# --- uplink liveness -------------------------------------------------------
# The link can be UP with a valid address and a default route while the phone's
# tethering has lost its upstream. Everything above this supervisor then looks
# healthy and only the traffic fails, which is indistinguishable from a fault on
# the head unit. Check the gateway, then the internet, and cycle the link when the
# first answers and the second does not.
PAN_IF=bt-pan
GW=
fail_streak=0

uplink_gw() {
    ip route show dev "$PAN_IF" 2>/dev/null | awk '/^default/ {print $3; exit}'
}

uplink_check() {
    GW=$(uplink_gw)
    [ -n "$GW" ] || return 1
    ping -c 1 -W 3 "$GW" >/dev/null 2>&1 || return 1
    ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && return 0
    return 2
}

PAN_COMPONENT=com.android.bluetooth/.pan.PanService
APP_COMPONENT=org.egmp.bluetoothpan/org.egmp.bluetoothpan.PanControllerService
LOGCAT_PID=

cleanup() {
    if [ -n "$LOGCAT_PID" ]; then
        kill "$LOGCAT_PID" >/dev/null 2>&1
        wait "$LOGCAT_PID" >/dev/null 2>&1
    fi
}

trap 'exit 0' 1 2 15
trap cleanup 0

start_pan() {
    pm enable --user 0 "$PAN_COMPONENT"
    am startservice -n "$PAN_COMPONENT" \
        --es action com.android.bluetooth.btservice.action.STATE_CHANGED \
        --ei android.bluetooth.adapter.extra.STATE 12
}

start_controller() {
    am startservice -n "$APP_COMPONENT"
}

while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

echo "===== Bluetooth PAN 3.0.0 diagnostic session $(date) ====="
echo "Bluetooth PAN: supervisor started"
logcat -v time -s BluetoothPanApp:I BluetoothPan:D PanService:D AndroidRuntime:E '*:S' &
LOGCAT_PID=$!
echo "Bluetooth PAN: diagnostic logcat pid=$LOGCAT_PID"
# Android can report boot complete before the Bluetooth adapter has restored
# its bonded-device database. Starting PanService in that window can leave it
# alive but unable to allocate bt-pan, so allow Bluetooth to settle first.
echo "Bluetooth PAN: waiting for Bluetooth startup"
sleep 10
start_pan
start_controller

while true; do
    sleep 15
    uplink_check
    rc=$?
    if [ "$rc" = "0" ]; then
        fail_streak=0
    elif [ "$rc" = "2" ]; then
        fail_streak=$((fail_streak + 1))
        echo "Bluetooth PAN: gateway $GW answers, internet does not (streak $fail_streak)"
        if [ "$fail_streak" -ge 4 ]; then
            echo "Bluetooth PAN: uplink dead for a minute; cycling $PAN_IF"
            ifconfig "$PAN_IF" down >/dev/null 2>&1
            sleep 5
            start_controller
            fail_streak=0
        fi
    else
        echo "Bluetooth PAN: no route on $PAN_IF"
    fi
    # Do not re-send the adapter-state initialization while PanService is
    # healthy: this stock implementation can lose its per-device state when it
    # receives that start request during an active connection.
    if ! dumpsys activity services com.android.bluetooth/.pan.PanService 2>/dev/null \
        | grep -q 'ServiceRecord'; then
        echo "Bluetooth PAN: stock PAN service stopped; starting it"
        start_pan
    fi
    if ! dumpsys activity services "$APP_COMPONENT" 2>/dev/null \
        | grep -q 'ServiceRecord'; then
        echo "Bluetooth PAN: controller stopped; starting it"
        start_controller
    fi
done
