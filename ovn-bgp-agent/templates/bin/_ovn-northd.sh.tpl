#!/bin/bash
set -ex

# Wait for databases
until [ -f /etc/ovn/ovnnb_db.db ] && [ -f /etc/ovn/ovnsb_db.db ]; do
    echo "Waiting for OVN databases..."
    sleep 2
done

echo "=== Starting OVN Northbound Services ==="

# Start NB ovsdb-server
ovsdb-server \
    --remote=punix:/var/run/ovn/ovnnb_db.sock \
    --unixctl=/var/run/ovn/ovnnb_db.ctl \
    --pidfile=/var/run/ovn/ovnnb_db.pid \
    --log-file=/var/log/ovn/ovsdb-server-nb.log \
    --detach \
    /etc/ovn/ovnnb_db.db

# Start SB ovsdb-server
ovsdb-server \
    --remote=punix:/var/run/ovn/ovnsb_db.sock \
    --unixctl=/var/run/ovn/ovnsb_db.ctl \
    --pidfile=/var/run/ovn/ovnsb_db.pid \
    --log-file=/var/log/ovn/ovsdb-server-sb.log \
    --detach \
    /etc/ovn/ovnsb_db.db

until [ -S /var/run/ovn/ovnnb_db.sock ] && [ -S /var/run/ovn/ovnsb_db.sock ]; do
    sleep 1
done

echo "=== Starting OVN Northd (foreground) ==="

exec ovn-northd \
    --ovnnb-db=unix:/var/run/ovn/ovnnb_db.sock \
    --ovnsb-db=unix:/var/run/ovn/ovnsb_db.sock \
    --unixctl=/var/run/ovn/ovn-northd.ctl \
    --log-file=/var/log/ovn/ovn-northd.log