#!/usr/bin/env python3

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

# Register the datastores and versions of bootstrap.structured.datastores
# and load the configuration group parameters of each version, with the
# functions trove-manage uses (datastore_update, datastore_version_update,
# db_load_datastore_config_parameters), but failing on an error (trove-manage
# prints some errors and exits 0) and leaving a datastore's default version
# alone when none is given (datastore_update clears it).
#
# Usage: bootstrap-datastores.py <datastores.json> [--check]
# --check writes nothing and prints what would change.

import json
import os
import sys

import trove
from trove.common import cfg
from trove.common import constants
from trove.common import exception
from trove.configuration import models as config_models
from trove.datastore import models as ds_models
from trove.db import get_db_api

CONF = cfg.CONF


def rules_file(manager, wanted):
    if wanted is False:
        return None
    if isinstance(wanted, str):
        return wanted
    path = os.path.join(os.path.dirname(trove.__file__), 'templates',
                        manager, 'validation-rules.json')
    return path if os.path.exists(path) else None


def find_datastore(name):
    try:
        return ds_models.DBDatastore.find_by(name=name)
    except exception.ModelNotFoundError:
        return None


def find_version(datastore, name, number):
    if datastore is None:
        return None
    try:
        return ds_models.DBDatastoreVersion.find_by(
            datastore_id=datastore.id, name=name, version=number)
    except exception.ModelNotFoundError:
        return None


def wanted_version(manager, v):
    """The columns datastore_version_update writes, as it would write them.

    The registry extension and the replication strategy are written by
    trove from the manager when not given; a trove without
    default_repl_strategy leaves the strategy unchecked (None).
    """
    tags = v.get('image_tags') or ''
    if isinstance(tags, list):
        tags = ','.join(tags)
    repl = v.get('repl_strategy')
    if not repl and hasattr(ds_models, 'default_repl_strategy'):
        repl = ds_models.default_repl_strategy(manager)
    return {
        'manager': manager,
        'image_id': v.get('image') or None,
        'image_tags': tags,
        'packages': v.get('packages', ''),
        'active': bool(v.get('active', True)),
        'registry_ext': (v.get('registry_ext') or
                         constants.REGISTRY_EXT_DEFAULTS.get(manager)),
        'repl_strategy': repl,
    }


def main(path, check):
    get_db_api().configure_db()
    with open(path) as f:
        datastores = json.load(f) or []
    changes = 0
    for ds in datastores:
        name = ds['name']
        current = find_datastore(name)
        if current is None:
            changes += 1
            print("datastore %s: new" % name)
            if not check:
                ds_models.update_datastore(name, None)
        for v in ds.get('versions') or []:
            vname = str(v['name'])
            number = str(v.get('version') or vname)
            manager = v.get('manager') or name
            want = wanted_version(manager, v)
            have = find_version(current, vname, number)
            diff = [] if have else ['new']
            for k in sorted(want) if have else []:
                value = getattr(have, k)
                if k == 'active':
                    value = bool(value)
                if want[k] is None and k != 'image_id':
                    continue
                if value != want[k]:
                    diff.append('%s %r -> %r' % (k, value, want[k]))
            if diff:
                changes += 1
                print("version %s %s (%s): %s"
                      % (name, vname, number, '; '.join(diff)))
                if not check:
                    ds_models.update_datastore_version(
                        name, vname, manager, want['image_id'],
                        want['image_tags'], want['packages'], want['active'],
                        registry_ext=v.get('registry_ext'),
                        repl_strategy=v.get('repl_strategy'), version=number)
            rules = rules_file(manager, v.get('config_parameters', True))
            if rules is None:
                print("version %s %s: no configuration parameters"
                      % (name, vname))
                continue
            with open(rules) as f:
                params = json.load(f)['configuration-parameters']
            loaded = set()
            if have is not None:
                loaded = {p.name for p in config_models.
                          DatastoreConfigurationParameters.
                          load_parameters(have.id)}
            missing = len({p['name'] for p in params} - loaded)
            print("version %s %s: %d parameters in %s, %d not loaded"
                  % (name, vname, len(params), rules, missing))
            if missing:
                changes += 1
            if not check:
                config_models.load_datastore_configuration_parameters(
                    name, vname, rules, version_number=number)
        default = ds.get('default_version')
        if default is not None:
            current = find_datastore(name)
            version = None
            if current is not None and current.default_version_id:
                version = ds_models.DBDatastoreVersion.find_by(
                    id=current.default_version_id).name
            if version != str(default):
                changes += 1
                print("datastore %s: default version %s -> %s"
                      % (name, version, default))
                if not check:
                    ds_models.update_datastore(name, str(default))
    print("%d change(s)%s" % (changes, ' (check only)' if check else ''))


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if a != '--check']
    cfg.parse_args(['trove-bootstrap', '--config-file',
                    os.environ.get('TROVE_CONF', '/etc/trove/trove.conf')])
    main(args[0], '--check' in sys.argv[1:])
