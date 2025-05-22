#!/bin/bash

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