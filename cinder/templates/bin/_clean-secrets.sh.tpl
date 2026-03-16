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

# Only delete secrets created by this release (release_group=cinder).
# Skip externally injected secrets that have a different or missing release_group label.
RELEASE_GROUP=$(kubectl get secret \
  --namespace ${NAMESPACE} \
  ${RBD_POOL_SECRET} \
  -o jsonpath='{.metadata.labels.release_group}' 2>/dev/null || true)

if [ "${RELEASE_GROUP}" = "cinder" ]; then
  kubectl delete secret \
    --namespace ${NAMESPACE} \
    --ignore-not-found=true \
    ${RBD_POOL_SECRET}
else
  echo "Secret ${RBD_POOL_SECRET} is externally managed (release_group=${RELEASE_GROUP}), skipping deletion."
fi
