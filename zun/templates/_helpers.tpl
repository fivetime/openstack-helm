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

{{/*
Zun API startup script
*/}}
{{- define "zun.bin.zun_api" -}}
#!/bin/bash
set -ex

# Create log directory
mkdir -p /var/log/zun

# Set ownership and permissions
chown zun:zun /var/log/zun
chmod 755 /var/log/zun

# Start the zun-api service
exec zun-api \
    --config-file /etc/zun/zun.conf \
    --log-file /var/log/zun/zun-api.log
{{- end }}

{{/*
Zun Compute startup script
*/}}
{{- define "zun.bin.zun_compute" -}}
#!/bin/bash
set -ex

# Create log directory
mkdir -p /var/log/zun

# Set ownership and permissions
chown zun:zun /var/log/zun
chmod 755 /var/log/zun

# Setup Docker group access
if [ -S /var/run/docker.sock ]; then
    echo "Setting up Docker socket access..."
    gid=$(stat -c "%g" /var/run/docker.sock)

    # Create docker group with the same GID as docker socket
    if ! getent group docker > /dev/null 2>&1; then
        groupadd --force --gid $gid docker
    fi

    # Add zun user to docker group
    usermod -aG docker zun

    # Verify docker access
    if groups zun | grep -q docker; then
        echo "Zun user successfully added to docker group"
    else
        echo "Warning: Failed to add zun user to docker group"
    fi
fi

# Test Docker connectivity
echo "Testing Docker connectivity..."
if docker version > /dev/null 2>&1; then
    echo "Docker connectivity test passed"
else
    echo "Warning: Docker connectivity test failed"
fi

# Start the zun-compute service
exec zun-compute \
    --config-file /etc/zun/zun.conf \
    --log-file /var/log/zun/zun-compute.log
{{- end }}

{{/*
Zun CNI Daemon startup script
*/}}
{{- define "zun.bin.zun_cni_daemon" -}}
#!/bin/bash
set -ex

# Create log directory
mkdir -p /var/log/zun

# Set ownership and permissions
chown zun:zun /var/log/zun
chmod 755 /var/log/zun

# Ensure CNI directories exist
echo "Setting up CNI directories..."
mkdir -p /etc/cni/net.d
mkdir -p /opt/cni/bin
mkdir -p /var/lib/cni

# Set proper permissions for CNI directories
chmod 755 /etc/cni/net.d
chmod 755 /opt/cni/bin
chmod 755 /var/lib/cni

# Check if CNI plugins are available
if [ -f /opt/cni/bin/loopback ]; then
    echo "CNI plugins found"
    ls -la /opt/cni/bin/
else
    echo "Warning: CNI plugins not found in /opt/cni/bin/"
fi

# Check for existing CNI configurations
if [ -d /etc/cni/net.d ]; then
    config_count=$(ls -1 /etc/cni/net.d/*.conf 2>/dev/null | wc -l)
    echo "Found $config_count CNI configuration files"
fi

# Start the zun-cni-daemon service
exec zun-cni-daemon \
    --config-file /etc/zun/zun.conf \
    --log-file /var/log/zun/zun-cni-daemon.log
{{- end }}

{{/*
Zun WebSocket Proxy startup script
*/}}
{{- define "zun.bin.zun_wsproxy" -}}
#!/bin/bash
set -ex

# Create log directory
mkdir -p /var/log/zun

# Set ownership and permissions
chown zun:zun /var/log/zun
chmod 755 /var/log/zun

# Start the zun-wsproxy service
exec zun-wsproxy \
    --config-file /etc/zun/zun.conf \
    --log-file /var/log/zun/zun-wsproxy.log
{{- end }}

{{/*
Database sync script
*/}}
{{- define "zun.bin.db_sync" -}}
#!/bin/bash
set -ex

# Wait for database to be ready
echo "Checking database connectivity..."
python3 -c "
import sys
import time
import pymysql
from oslo_config import cfg
from zun.conf import CONF

cfg.CONF([], project='zun')

max_retries = 30
retry_interval = 10

for attempt in range(max_retries):
    try:
        # Parse connection string
        db_url = CONF.database.connection
        if not db_url:
            print('No database connection configured')
            sys.exit(1)

        print(f'Testing database connection (attempt {attempt + 1}/{max_retries})...')

        # Simple connection test
        import sqlalchemy
        engine = sqlalchemy.create_engine(db_url)
        with engine.connect() as conn:
            conn.execute(sqlalchemy.text('SELECT 1'))

        print('Database connection successful')
        break

    except Exception as e:
        print(f'Database connection failed: {e}')
        if attempt < max_retries - 1:
            print(f'Retrying in {retry_interval} seconds...')
            time.sleep(retry_interval)
        else:
            print('Max retries exceeded')
            sys.exit(1)
"

# Run database migration
echo "Running Zun database migration..."
zun-db-manage upgrade

echo "Database migration completed successfully"
{{- end }}

{{/*
Database drop script
*/}}
{{- define "zun.bin.db_drop" -}}
#!/bin/bash
set -ex

echo "WARNING: This will drop all Zun database tables!"
echo "This operation cannot be undone."

# Confirm database connection
python3 -c "
import sys
from oslo_config import cfg
from zun.conf import CONF

cfg.CONF([], project='zun')

db_url = CONF.database.connection
if not db_url:
    print('No database connection configured')
    sys.exit(1)

print(f'Database URL: {db_url}')
"

# Drop database tables
echo "Dropping Zun database tables..."
zun-db-manage drop_schema

echo "Database drop completed"
{{- end }}