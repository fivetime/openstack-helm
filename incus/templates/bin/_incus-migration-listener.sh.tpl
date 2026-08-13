#!/bin/sh

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

set -eu

MODE=${1:-}
STATE={{ .Values.incus.state_path | quote }}
ENABLED=${INCUS_MIGRATION_ENABLED:-false}
INTERFACE=${INCUS_MIGRATION_INTERFACE:-}
NETWORK_CIDR=${INCUS_MIGRATION_NETWORK_CIDR:-}
PORT=${INCUS_MIGRATION_PORT:-8443}

fail() {
    echo "incus-migration-listener: $*" >&2
    exit 1
}

resolve_address() {
    interface=$INTERFACE
    if [ -z "$interface" ] && [ -n "$NETWORK_CIDR" ]; then
        interface=$(ip -4 route list "$NETWORK_CIDR" \
            | awk -F 'dev' '{ print $2; exit }' \
            | awk '{ print $1 }')
        [ -n "$interface" ] || fail \
            "no IPv4 route found for migration network $NETWORK_CIDR"
    fi

    if [ -n "$interface" ]; then
        address=$(ip -4 -o addr show dev "$interface" scope global \
            | awk '{ print $4 }' \
            | cut -d/ -f1 \
            | head -1)
    else
        address=${HOST_IP:-}
    fi

    [ -n "$address" ] || fail "cannot determine an IPv4 migration address"
    case "$address" in
        *:*) fail "IPv6 migration addresses are not supported: $address" ;;
    esac
    printf '%s\n' "$address"
}

if [ "$ENABLED" != "true" ]; then
    case "$MODE" in
        configure)
            INCUS_DIR="$STATE" incus admin waitready --timeout=120 >/dev/null
            actual=$(INCUS_DIR="$STATE" incus config get core.https_address)
            if [ -n "$actual" ]; then
                INCUS_DIR="$STATE" incus config unset core.https_address
                actual=$(INCUS_DIR="$STATE" incus config get core.https_address)
            fi
            ;;
        check)
            actual=$(INCUS_DIR="$STATE" incus config get core.https_address)
            ;;
        *)
            fail "usage: $0 {configure|check}"
            ;;
    esac

    [ -z "$actual" ] || fail \
        "core.https_address is '$actual', expected no remote listener"
    exit 0
fi

case "$PORT" in
    ''|*[!0-9]*) fail "migration port is not numeric: $PORT" ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    fail "migration port is outside 1-65535: $PORT"
fi

address=$(resolve_address)
desired="${address}:${PORT}"

case "$MODE" in
    configure)
        INCUS_DIR="$STATE" incus admin waitready --timeout=120 >/dev/null
        actual=$(INCUS_DIR="$STATE" incus config get core.https_address)
        if [ "$actual" != "$desired" ]; then
            INCUS_DIR="$STATE" incus config set core.https_address "$desired"
            actual=$(INCUS_DIR="$STATE" incus config get core.https_address)
        fi
        ;;
    check)
        actual=$(INCUS_DIR="$STATE" incus config get core.https_address)
        ;;
    *)
        fail "usage: $0 {configure|check}"
        ;;
esac

[ "$actual" = "$desired" ] || fail \
    "core.https_address is '$actual', expected '$desired'"
