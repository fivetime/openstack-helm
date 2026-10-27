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

# The JWKS Envoy checks a console token with, from the public key zun-wsproxy
# checks it with: one key, two checks.
python3 -m zun.websocket.console_token \
    {{ required "network.wsproxy.edge needs conf.zun.websocket_proxy.token_verify_key" .Values.conf.zun.websocket_proxy.token_verify_key }} \
    > /etc/zun-wsproxy-edge/jwks.json
python3 /tmp/wsproxy-edge-envoy-config.py > /etc/zun-wsproxy-edge/envoy.json
