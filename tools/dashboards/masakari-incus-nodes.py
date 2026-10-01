#!/usr/bin/env python3
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Generate the Grafana dashboard of the Incus monitor of the masakari chart.

    tools/dashboards/masakari-incus-nodes.py \
        > masakari/dashboards/incus-nodes.json
"""

import json

DS = {"type": "prometheus", "uid": "${DS_PROMETHEUS}"}
N = 'node=~"$node"'
POD = 'instance, pod, container, endpoint, job, namespace, host'

# Every Incus instance the exporter judged, with its Nova instance: the join
# that puts a Nova UUID next to the official per-instance metrics.
MAP = ('group by (node, incus_instance, nova_uuid) '
       '(incus_exporter_instance_apparmor_stacked{%s})' % N)


def official(expr):
    """Official Incus metric keyed like the exporter's, with the Nova UUID."""
    return ('max by (node, incus_instance, nova_uuid) (label_replace(%s, '
            '"incus_instance", "$1", "name", "(.+)") * on (node, '
            'incus_instance) group_left (nova_uuid) %s)' % (expr, MAP))


_id = [0]


def pid():
    _id[0] += 1
    return _id[0]


def target(expr, ref, legend=None, instant=False, fmt=None):
    t = {"datasource": DS, "expr": expr, "refId": ref,
         "instant": instant, "range": not instant}
    if legend:
        t["legendFormat"] = legend
    if fmt:
        t["format"] = fmt
    return t


def row(title, y):
    return {"type": "row", "title": title, "id": pid(), "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


def table(title, desc, queries, renames, pos, overrides=(), sort=None):
    order = {name: i for i, name in enumerate(renames.values())}
    excluded = {"Time": True}
    return {
        "type": "table", "title": title, "description": desc, "id": pid(),
        "datasource": DS, "gridPos": pos,
        "targets": [target(q, chr(65 + i), instant=True, fmt="table")
                    for i, q in enumerate(queries)],
        "transformations": [
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {
                "excludeByName": excluded,
                "renameByName": renames,
                "indexByName": order}},
        ],
        "options": {"showHeader": True, "cellHeight": "sm",
                    "sortBy": [sort] if sort else []},
        "fieldConfig": {"defaults": {"custom": {"align": "auto",
                                                "filterable": True}},
                        "overrides": list(overrides)},
    }


def bool_cells(field, good, bad, good_text, bad_text):
    return {"matcher": {"id": "byName", "options": field}, "properties": [
        {"id": "custom.cellOptions", "value": {"type": "color-background"}},
        {"id": "mappings", "value": [{"type": "value", "options": {
            good: {"text": good_text, "color": "green"},
            bad: {"text": bad_text, "color": "red"}}}]}]}


def threshold_cells(field, unit, warn, crit, decimals=None):
    props = [
        {"id": "unit", "value": unit},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}},
        {"id": "thresholds", "value": {"mode": "absolute", "steps": [
            {"color": "green", "value": None},
            {"color": "orange", "value": warn},
            {"color": "red", "value": crit}]}}]
    if decimals is not None:
        props.append({"id": "decimals", "value": decimals})
    return {"matcher": {"id": "byName", "options": field},
            "properties": props}


def timeseries(title, desc, targets, pos, unit="short", bars=False,
               stack=False):
    custom = {"drawStyle": "bars" if bars else "line", "fillOpacity":
              60 if bars else 10, "lineWidth": 1, "showPoints": "never"}
    if stack:
        custom["stacking"] = {"mode": "normal", "group": "A"}
    return {"type": "timeseries", "title": title, "description": desc,
            "id": pid(), "datasource": DS, "gridPos": pos,
            "targets": targets,
            "fieldConfig": {"defaults": {"unit": unit, "custom": custom,
                                         "min": 0},
                            "overrides": []},
            "options": {"legend": {"displayMode": "table",
                                   "placement": "right",
                                   "calcs": ["lastNotNull", "max"]},
                        "tooltip": {"mode": "multi"}}}


def timeline(title, desc, targets, pos, mapping):
    return {"type": "state-timeline", "title": title, "description": desc,
            "id": pid(), "datasource": DS, "gridPos": pos,
            "targets": targets,
            "fieldConfig": {"defaults": {
                "custom": {"fillOpacity": 80, "lineWidth": 0},
                "mappings": [{"type": "value", "options": mapping}],
                "color": {"mode": "thresholds"},
                "thresholds": {"mode": "absolute",
                               "steps": [{"color": "green", "value": None}]}},
                "overrides": []},
            "options": {"showValue": "never", "mergeValues": True,
                        "rowHeight": 0.8,
                        "legend": {"showLegend": False}}}


panels = []
y = 0

# ---------------------------------------------------------------- nodes
panels.append(row("Nodes", y))
y += 1
panels.append(table(
    "Incus nodes",
    "One row per Incus compute. LXCFS and incusd columns come from the "
    "masakari Incus exporter, instance counts too; Recovery is the "
    "notifier's mode on the node, Withheld the number of reasons it is "
    "holding recoveries back for.",
    [
        'max by (node) (incus_exporter_instances_running{%s})' % N,
        'max by (node) (incus_exporter_instances_state{%s,state="stale"})' % N,
        'max by (node) (incus_exporter_instances_confinement'
        '{%s,state="stacked"})' % N,
        'max by (node) (incus_exporter_host_lxcfs_up{%s})' % N,
        'max by (node) (incus_exporter_incusd_lxcfs_fresh{%s})' % N,
        'max by (node) (incus_exporter_incusd_launches_stacked{%s})' % N,
        'max by (node) (incus_exporter_host_lxcfs_start_time_seconds{%s}) '
        '* 1000' % N,
        'max by (node) (incus_notifier_dry_run{%s})' % N,
        'sum by (node) (incus_notifier_autoheal_blocked{%s})' % N,
        'count by (node) (incus_notifier_instance_awaiting_manual{%s} == 1)'
        ' or max by (node) (incus_notifier_dry_run{%s}) * 0' % (N, N),
        'time() - max by (node) '
        '(incus_exporter_last_sweep_timestamp_seconds{%s})' % N,
    ],
    {"node": "Node", "Value #A": "Running", "Value #B": "LXCFS stale",
     "Value #C": "AppArmor stacked", "Value #D": "Host LXCFS",
     "Value #E": "incusd LXCFS view", "Value #F": "New instances",
     "Value #G": "LXCFS started", "Value #H": "Recovery",
     "Value #I": "Withheld", "Value #J": "Awaiting manual",
     "Value #K": "Last probe"},
    {"h": 6, "w": 24, "x": 0, "y": y},
    overrides=[
        threshold_cells("LXCFS stale", "short", 1, 1),
        threshold_cells("AppArmor stacked", "short", 1, 1),
        bool_cells("Host LXCFS", "1", "0", "up", "DOWN"),
        bool_cells("incusd LXCFS view", "1", "0", "fresh", "STALE"),
        bool_cells("New instances", "0", "1", "confined", "STACKED"),
        {"matcher": {"id": "byName", "options": "LXCFS started"},
         "properties": [{"id": "unit", "value": "dateTimeFromNow"}]},
        {"matcher": {"id": "byName", "options": "Recovery"},
         "properties": [
             {"id": "custom.cellOptions",
              "value": {"type": "color-background"}},
             {"id": "mappings", "value": [{"type": "value", "options": {
                 "1": {"text": "dry run", "color": "blue"},
                 "0": {"text": "armed", "color": "green"}}}]}]},
        threshold_cells("Withheld", "short", 1, 1),
        threshold_cells("Awaiting manual", "short", 1, 1),
        threshold_cells("Last probe", "s", 60, 120, decimals=0),
    ]))
y += 6
panels.append(timeseries(
    "Stale and stacked instances",
    "Instances bound to a dead LXCFS mount, and instances whose AppArmor "
    "label stacks unconfined, per node.",
    [target('max by (node) (incus_exporter_instances_state'
            '{%s,state="stale"})' % N, "A", "{{node}} LXCFS stale"),
     target('max by (node) (incus_exporter_instances_confinement'
            '{%s,state="stacked"})' % N, "B", "{{node}} AppArmor stacked")],
    {"h": 8, "w": 12, "x": 0, "y": y}))
panels.append(timeline(
    "LXCFS and incusd",
    "Host LXCFS answering, and incusd bound to the mount the host serves. "
    "A gap in incusd's view after an LXCFS restart closes when its "
    "liveness probe replaces the incusd container.",
    [target('max by (node) (incus_exporter_host_lxcfs_up{%s})' % N, "A",
            "{{node}} host LXCFS"),
     target('max by (node) (incus_exporter_incusd_lxcfs_fresh{%s})' % N,
            "B", "{{node}} incusd view"),
     target('clamp_max(sum by (node) (increase('
            'incus_exporter_host_lxcfs_device_changes_total{%s}[5m])), 1) '
            '* -1 + 1' % N, "C", "{{node}} no LXCFS restart (5m)")],
    {"h": 8, "w": 12, "x": 12, "y": y},
    {"1": {"text": "ok", "color": "green"},
     "0": {"text": "problem", "color": "red"}}))
y += 8

# ------------------------------------------------------------ instances
panels.append(row("Instances", y))
y += 1
inst_link = [{"title": "Open in Incus resources",
              "url": "/d/incus-official/incus-resources?var-job=incus-"
                     "${__data.fields.Node}&var-project=default"
                     "&var-name=${__value.raw}"}]
panels.append(table(
    "Incus instances",
    "Every running instance the exporter judged, with its Nova instance. "
    "Resource columns are the official Incus metrics. Click an instance "
    "name to open it in Incus resources, the official Incus dashboard.",
    [
        'max by (node, incus_instance, nova_uuid) '
        '(incus_exporter_instance_lxcfs_stale{%s})' % N,
        'max by (node, incus_instance, nova_uuid) '
        '(incus_exporter_instance_apparmor_stacked{%s})' % N,
        official('1 - incus_memory_MemAvailable_bytes{%s} / '
                 'incus_memory_MemTotal_bytes{%s}' % (N, N)),
        official('1 - incus_filesystem_avail_bytes{%s,mountpoint="/"} / '
                 'incus_filesystem_size_bytes{%s,mountpoint="/"}' % (N, N)),
        official('incus_procs_total{%s}' % N),
        official('increase(incus_memory_OOM_kills_total{%s}[24h])' % N),
        'max by (node, incus_instance, nova_uuid) '
        '(incus_notifier_instance_awaiting_manual{%s}) or '
        '%s * 0' % (N, MAP.replace('group by', 'max by')),
    ],
    {"node": "Node", "incus_instance": "Instance", "nova_uuid": "Nova UUID",
     "Value #A": "LXCFS", "Value #B": "AppArmor", "Value #C": "Memory used",
     "Value #D": "Root disk used", "Value #E": "Processes",
     "Value #F": "OOM kills 24h", "Value #G": "Awaiting manual"},
    {"h": 10, "w": 24, "x": 0, "y": y},
    overrides=[
        {"matcher": {"id": "byName", "options": "Instance"},
         "properties": [{"id": "links", "value": inst_link}]},
        bool_cells("LXCFS", "0", "1", "fresh", "STALE"),
        bool_cells("AppArmor", "0", "1", "confined", "STACKED"),
        threshold_cells("Memory used", "percentunit", 0.9, 0.95,
                        decimals=1),
        threshold_cells("Root disk used", "percentunit", 0.8, 0.9,
                        decimals=1),
        threshold_cells("OOM kills 24h", "short", 1, 1, decimals=0),
        bool_cells("Awaiting manual", "0", "1", "no", "YES"),
    ],
    sort={"displayName": "Node", "desc": False}))
y += 10

# ------------------------------------------------------- self-healing
panels.append(row("Self-healing", y))
y += 1
panels.append(timeline(
    "Recovery withheld",
    "Why the notifier sends nothing from a node. Every reason must clear "
    "before an instance is recovered.",
    [target('max by (node, reason) (incus_notifier_autoheal_blocked{%s}) '
            '== 1' % N, "A", "{{node}} {{reason}}")],
    {"h": 8, "w": 12, "x": 0, "y": y},
    {"1": {"text": "withheld", "color": "red"}}))
panels.append(timeseries(
    "Notifications to Masakari",
    "What became of the notifications the notifier sent, per result. "
    "dry-run counts the ones a dry run only logged.",
    [target('sum by (node, result) (increase('
            'incus_notifier_notifications_total{%s}[5m])) > 0' % N, "A",
            "{{node}} {{result}}")],
    {"h": 8, "w": 12, "x": 12, "y": y}, bars=True, stack=True))
y += 8
panels.append(timeseries(
    "Recoveries",
    "How the recoveries Masakari ran ended: recovered, skipped (the "
    "instance is not HA_Enabled), ineffective, error or timeout.",
    [target('sum by (node, result) (increase('
            'incus_notifier_recoveries_total{%s}[5m])) > 0' % N, "A",
            "{{node}} {{result}}")],
    {"h": 8, "w": 12, "x": 0, "y": y}, bars=True, stack=True))
panels.append(timeseries(
    "Recovery in flight and duration",
    "Recoveries Masakari is still running, and how long finished ones "
    "took from notification to a live mount.",
    [target('max by (node) (incus_notifier_recovery_in_flight{%s})' % N,
            "A", "{{node}} in flight"),
     target('sum by (node) (increase(incus_notifier_recovery_seconds_sum'
            '{%s}[1h])) / sum by (node) (increase('
            'incus_notifier_recovery_seconds_count{%s}[1h])) > 0' % (N, N),
            "B", "{{node}} mean seconds (1h)")],
    {"h": 8, "w": 12, "x": 12, "y": y}))
y += 8

dash = {
    "uid": "incus-nodes-autoheal",
    "title": "Incus faults",
    "description": "Per-node LXCFS, AppArmor and self-healing state of the "
                   "Incus computes, from the masakari Incus exporter and "
                   "notifier, next to the official Incus metrics.",
    "tags": ["incus", "masakari"],
    "editable": True, "graphTooltip": 1, "schemaVersion": 39,
    "time": {"from": "now-6h", "to": "now"}, "refresh": "1m",
    "links": [{"title": "Incus resources", "type": "link",
               "url": "/d/incus-official/incus-resources", "icon": "dashboard",
               "targetBlank": False}],
    "templating": {"list": [{
        "name": "node", "label": "Node", "type": "query", "datasource": DS,
        "query": {"query": "label_values(incus_exporter_last_sweep_timestamp"
                           "_seconds, node)", "refId": "node"},
        "definition": "label_values(incus_exporter_last_sweep_timestamp"
                      "_seconds, node)",
        "refresh": 2, "multi": True, "includeAll": True, "sort": 1,
        "current": {"text": "All", "value": "$__all"}}]},
    "panels": panels,
}
print(json.dumps(dash, indent=2))
