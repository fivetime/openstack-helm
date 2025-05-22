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