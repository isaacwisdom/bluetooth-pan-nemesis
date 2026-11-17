#!/system/bin/sh
# Install the APK from a directory the package manager accepts.
#
# On OSNPE23 firmware, `pm install -r` fails for an APK inside
# /data/nemesis/apps/<id>/app/ with INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES and succeeds
# for the same bytes under /data/local/tmp -- same mode, owner and parent permissions. NEMESIS's
# own pm step therefore fails, the package record is never written, and pan-supervisor never
# starts. Install it here instead, idempotently.
PKG=org.egmp.bluetoothpan
BASE=/data/nemesis/apps/bluetooth.pan
APK="$BASE/app/BluetoothPan.apk"

if pm path "$PKG" 2>/dev/null | grep -q package:; then
    echo "postinstall: $PKG already installed"
    exit 0
fi
[ -f "$APK" ] || { echo "postinstall: missing $APK"; exit 1; }
mkdir -p /data/local/tmp/pan
cp -f "$APK" /data/local/tmp/pan/BluetoothPan.apk || exit 1
PREV=$(getprop sys.boot_completed)
setprop sys.boot_completed 0
pm install -r /data/local/tmp/pan/BluetoothPan.apk
RC=$?
setprop sys.boot_completed "${PREV:-1}"
echo "postinstall: pm install rc=$RC"
exit $RC
