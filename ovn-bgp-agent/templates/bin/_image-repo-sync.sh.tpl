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

# Check if LOCAL_REPO is set
if [ -z "${LOCAL_REPO}" ]; then
  echo "ERROR: LOCAL_REPO environment variable is not set"
  exit 1
fi

# Check if IMAGE_SYNC_LIST is set
if [ -z "${IMAGE_SYNC_LIST}" ]; then
  echo "ERROR: IMAGE_SYNC_LIST environment variable is not set"
  exit 1
fi

# Function to sync a single image
sync_image() {
  local source_image=$1
  local target_image=$2

  echo "Syncing image: ${source_image} -> ${target_image}"

  # Pull the source image
  if ! docker pull "${source_image}"; then
    echo "ERROR: Failed to pull ${source_image}"
    return 1
  fi

  # Tag the image for local registry
  if ! docker tag "${source_image}" "${target_image}"; then
    echo "ERROR: Failed to tag ${source_image} as ${target_image}"
    return 1
  fi

  # Push to local registry
  if ! docker push "${target_image}"; then
    echo "ERROR: Failed to push ${target_image}"
    return 1
  fi

  # Clean up local images to save space
  docker rmi "${source_image}" "${target_image}" || true

  echo "Successfully synced: ${source_image}"
  return 0
}

# Parse IMAGE_SYNC_LIST and sync each image
# Format: "source1,target1 source2,target2 ..."
IFS=' ' read -ra IMAGES <<< "${IMAGE_SYNC_LIST}"

failed_count=0
success_count=0

for image_pair in "${IMAGES[@]}"; do
  IFS=',' read -r source target <<< "${image_pair}"

  if [ -z "${source}" ] || [ -z "${target}" ]; then
    echo "WARNING: Invalid image pair format: ${image_pair}"
    continue
  fi

  if sync_image "${source}" "${LOCAL_REPO}/${target}"; then
    ((success_count++))
  else
    ((failed_count++))
  fi
done

echo "=================================================="
echo "Image sync completed:"
echo "  Success: ${success_count}"
echo "  Failed:  ${failed_count}"
echo "=================================================="

if [ ${failed_count} -gt 0 ]; then
  echo "WARNING: Some images failed to sync"
  exit 1
fi

echo "All images synced successfully"
exit 0