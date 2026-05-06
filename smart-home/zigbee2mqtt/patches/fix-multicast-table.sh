#!/bin/sh
# Fix: zigbee-herdsman ember adapter never sends MULTICAST_TABLE_SIZE to NCP firmware
# Bug: MULTICAST_TABLE_SIZE is loaded from stack_config.json and logged, but the
# emberSetEzspConfigValue() call is missing from initEzsp(). The NCP uses its
# compiled-in default (16), which is too small for 9+ groups.
# This script patches emberAdapter.js at container start to add the missing call.
# Safe to re-run: skips if patch is already applied or upstream fixes the bug.

ADAPTER=$(find /app/node_modules -name "emberAdapter.js" -path "*/ember/adapter/*" 2>/dev/null | head -1)

if [ -z "$ADAPTER" ]; then
    echo "[z2m-patch] emberAdapter.js not found, skipping"
elif grep -q "EzspConfigId.MULTICAST_TABLE_SIZE" "$ADAPTER"; then
    echo "[z2m-patch] MULTICAST_TABLE_SIZE patch already present, skipping"
else
    sed -i "/WARNING: From here on EZSP commands that affect memory allocation/i\\        await this.emberSetEzspConfigValue(enums_2.EzspConfigId.MULTICAST_TABLE_SIZE, this.stackConfig.MULTICAST_TABLE_SIZE || 16);" "$ADAPTER"
    if grep -q "EzspConfigId.MULTICAST_TABLE_SIZE" "$ADAPTER"; then
        echo "[z2m-patch] Applied MULTICAST_TABLE_SIZE patch to $ADAPTER"
    else
        echo "[z2m-patch] WARNING: Patch failed to apply"
    fi
fi

exec docker-entrypoint.sh "$@"
