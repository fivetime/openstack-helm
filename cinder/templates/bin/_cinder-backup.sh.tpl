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

{{- if empty .Values.conf.cinder.DEFAULT.host }}
# 仅当 host 为空(A/A,conf.cinder.DEFAULT.host=null)时固定 host,避免它退化成
# pod 名:backup 是 Deployment,pod 名随每次重建(滚动/删除/重调度)变化,会在
# `cinder-manage service list` 留下大量 down 的幽灵记录。多副本共享同一 host 安全
# ——监听同一 backup topic 竞争消费(每消息只投一个),备份归属该 host、任意副本可
# 做 create/delete/restore,并发由全局 tooz(etcd)协调把关。
# host 已显式配置时(如默认 cinder-volume-worker)不进此分支,行为与上游一致。
cat > /tmp/cinder-backup-host.conf <<EOF
[DEFAULT]
host = cinder-backup
EOF
{{- end }}

exec cinder-backup \
     --config-file /etc/cinder/cinder.conf \
{{- if empty .Values.conf.cinder.DEFAULT.host }}
     --config-file /tmp/cinder-backup-host.conf \
{{- end }}
     --config-dir /etc/cinder/cinder.conf.d
