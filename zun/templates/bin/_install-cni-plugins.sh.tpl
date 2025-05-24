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

# CNI plugin settings from values.yaml
CNI_VERSION="{{ .Values.network.drivers.cni.plugins.version }}"
CNI_BIN_DIR="{{ .Values.network.drivers.cni.paths.bin_dir }}"
INSTALL_MAIN="{{ .Values.network.drivers.cni.plugins.install.main }}"
INSTALL_IPAM="{{ .Values.network.drivers.cni.plugins.install.ipam }}"
INSTALL_META="{{ .Values.network.drivers.cni.plugins.install.meta }}"
INSTALL_WINDOWS="{{ .Values.network.drivers.cni.plugins.install.windows }}"

# Create CNI bin directory if it doesn't exist
mkdir -p ${CNI_BIN_DIR}

# Version tracking
VERSION_FILE="${CNI_BIN_DIR}/.cni-plugins-version"
INSTALL_MARKER="${CNI_BIN_DIR}/.cni-plugins-installed"

echo "=== CNI Plugins Installation Check ==="
echo "Target version: ${CNI_VERSION}"
echo "Installation directory: ${CNI_BIN_DIR}"

# Function to check if installation is needed
check_installation_needed() {
    # Check if version file exists and matches current version
    if [ -f "$VERSION_FILE" ]; then
        INSTALLED_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
        echo "Installed version: $INSTALLED_VERSION"

        if [ "$INSTALLED_VERSION" = "$CNI_VERSION" ]; then
            # Check if install marker exists and key plugins are present
            if [ -f "$INSTALL_MARKER" ]; then
                echo "Verifying existing installation..."

                # Check for essential plugins
                local essential_plugins="bridge loopback"
                local missing_count=0

                for plugin in $essential_plugins; do
                    if [ ! -f "${CNI_BIN_DIR}/$plugin" ]; then
                        echo "⚠ Essential plugin missing: $plugin"
                        missing_count=$((missing_count + 1))
                    fi
                done

                if [ $missing_count -eq 0 ]; then
                    echo "✓ CNI plugins ${CNI_VERSION} already installed and verified"
                    return 1  # No installation needed
                else
                    echo "⚠ Installation incomplete, will reinstall"
                fi
            else
                echo "⚠ Installation marker missing, will reinstall"
            fi
        else
            echo "⚠ Version mismatch, will upgrade from $INSTALLED_VERSION to $CNI_VERSION"
        fi
    else
        echo "⚠ No version file found, will install"
    fi

    return 0  # Installation needed
}

# Function to download and install plugins
install_cni_plugins() {
    echo ""
    echo "=== Installing CNI Plugins ${CNI_VERSION} ==="

    # Change to temp directory
    cd /tmp

    GITHUB_URL="https://github.com/containernetworking/plugins/releases/download"
    DOWNLOAD_URL="${GITHUB_URL}/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
    DOWNLOAD_FILE="cni-plugins-linux-amd64-${CNI_VERSION}.tgz"

    # Clean up any existing download
    rm -f "$DOWNLOAD_FILE"

    echo "Downloading from: $DOWNLOAD_URL"

    # Download with retries
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        echo "Download attempt $attempt/$max_attempts..."

        if curl -L -f \
                --connect-timeout 30 \
                --max-time 300 \
                --retry 2 \
                --retry-delay 5 \
                -o "$DOWNLOAD_FILE" \
                "$DOWNLOAD_URL"; then
            echo "✓ Download successful"
            break
        else
            echo "✗ Download attempt $attempt failed"
            if [ $attempt -eq $max_attempts ]; then
                echo "All download attempts failed"
                exit 1
            fi
            sleep 10
        fi

        attempt=$((attempt + 1))
    done

    # Verify download
    if [ ! -f "$DOWNLOAD_FILE" ] || [ ! -s "$DOWNLOAD_FILE" ]; then
        echo "✗ Downloaded file is missing or empty"
        exit 1
    fi

    echo "Downloaded file size: $(du -h $DOWNLOAD_FILE | cut -f1)"

    # Extract plugins
    echo "Extracting CNI plugins to ${CNI_BIN_DIR}..."
    if ! tar -xzf "$DOWNLOAD_FILE" -C "${CNI_BIN_DIR}"; then
        echo "✗ Failed to extract CNI plugins"
        exit 1
    fi

    # Clean up download file
    rm -f "$DOWNLOAD_FILE"

    echo "✓ CNI plugins extracted successfully"
}

# Function to clean up unwanted plugins
cleanup_plugins() {
    echo ""
    echo "=== Cleaning up unwanted plugins ==="

    cd "${CNI_BIN_DIR}"

    # List of plugin categories
    MAIN_PLUGINS="bridge ipvlan loopback macvlan ptp vlan host-device dummy"
    IPAM_PLUGINS="dhcp host-local static"
    META_PLUGINS="tuning portmap bandwidth sbr firewall"
    WINDOWS_PLUGINS="win-bridge win-overlay"

    # Function to remove plugins
    remove_plugins() {
        local category="$1"
        local plugins="$2"
        echo "Processing $category plugins..."

        for plugin in $plugins; do
            if [ -f "$plugin" ]; then
                echo "  Removing $category plugin: $plugin"
                rm -f "$plugin"
            fi
        done
    }

    # Remove unwanted plugins based on configuration
    if [ "${INSTALL_MAIN}" != "true" ]; then
        remove_plugins "main" "${MAIN_PLUGINS}"
    else
        echo "Keeping main plugins"
    fi

    if [ "${INSTALL_IPAM}" != "true" ]; then
        remove_plugins "IPAM" "${IPAM_PLUGINS}"
    else
        echo "Keeping IPAM plugins"
    fi

    if [ "${INSTALL_META}" != "true" ]; then
        remove_plugins "meta" "${META_PLUGINS}"
    else
        echo "Keeping meta plugins"
    fi

    if [ "${INSTALL_WINDOWS}" != "true" ]; then
        remove_plugins "Windows" "${WINDOWS_PLUGINS}"
    else
        echo "Keeping Windows plugins"
    fi
}

# Function to create zun-cni plugin
create_zun_cni() {
    echo ""
    echo "=== Creating zun-cni plugin ==="

    local zun_cni_path="${CNI_BIN_DIR}/zun-cni"

    # Check if we have a real zun-cni implementation
    if command -v zun-cni >/dev/null 2>&1 && [ "$(command -v zun-cni)" != "$zun_cni_path" ]; then
        echo "Found zun-cni command, copying..."
        cp "$(command -v zun-cni)" "$zun_cni_path"
        chmod +x "$zun_cni_path"
        echo "✓ Copied zun-cni binary"
    else
        echo "Creating zun-cni wrapper (temporary solution)..."
        cat > "$zun_cni_path" << 'EOF'
#!/bin/bash
# Zun CNI Plugin Wrapper
# This communicates with zun-cni-daemon for network operations
# WARNING: This is a temporary implementation

set -e

# Log function for debugging
log_debug() {
    echo "[$(date)] zun-cni: $*" >> /var/log/zun-cni.log 2>/dev/null || true
}

# CNI environment variables validation
# CNI_COMMAND: ADD, DEL, CHECK, or VERSION
# CNI_CONTAINERID: container ID
# CNI_NETNS: network namespace path
# CNI_IFNAME: interface name (e.g., eth0)
# CNI_ARGS: additional arguments
# CNI_PATH: path to CNI binaries

log_debug "Called with command: $CNI_COMMAND, container: $CNI_CONTAINERID"

# Basic validation
if [ -z "$CNI_COMMAND" ]; then
    echo '{"cniVersion":"0.4.0","code":2,"msg":"CNI_COMMAND not set"}' >&2
    exit 1
fi

case "$CNI_COMMAND" in
    VERSION)
        cat << 'VERSION_EOF'
{
    "cniVersion": "0.4.0",
    "supportedVersions": ["0.3.0", "0.3.1", "0.4.0"]
}
VERSION_EOF
        ;;
    ADD|DEL|CHECK)
        # Validate required parameters for these commands
        if [ -z "$CNI_CONTAINERID" ]; then
            echo '{"cniVersion":"0.4.0","code":2,"msg":"CNI_CONTAINERID not set"}' >&2
            exit 1
        fi

        log_debug "Operation: $CNI_COMMAND for container $CNI_CONTAINERID"

        # TODO: Replace this with actual communication to zun-cni-daemon
        # For now, delegate to bridge plugin as a fallback

        # Find bridge plugin
        BRIDGE_PLUGIN=""
        for bridge_path in "/opt/cni/bin/bridge" "${CNI_PATH}/bridge" "${0%/*}/bridge"; do
            if [ -x "$bridge_path" ]; then
                BRIDGE_PLUGIN="$bridge_path"
                break
            fi
        done

        if [ -z "$BRIDGE_PLUGIN" ]; then
            echo '{"cniVersion":"0.4.0","code":7,"msg":"bridge plugin not found"}' >&2
            exit 1
        fi

        log_debug "Delegating to bridge plugin: $BRIDGE_PLUGIN"
        exec "$BRIDGE_PLUGIN" "$@"
        ;;
    *)
        echo '{"cniVersion":"0.4.0","code":2,"msg":"unknown CNI_COMMAND: '$CNI_COMMAND'"}' >&2
        exit 1
        ;;
esac
EOF
        chmod +x "$zun_cni_path"
        echo "⚠ Created zun-cni wrapper that delegates to bridge plugin"
        echo "⚠ This is a temporary solution - real zun-cni implementation needed"
        log_debug "zun-cni wrapper created at $zun_cni_path"
    fi
}

# Function to finalize installation
finalize_installation() {
    echo ""
    echo "=== Finalizing installation ==="

    # Set proper permissions for all plugins
    chmod -R 755 "${CNI_BIN_DIR}"

    # Write version file
    echo "$CNI_VERSION" > "$VERSION_FILE"
    echo "✓ Version file updated: $VERSION_FILE"

    # Create install marker with timestamp and configuration
    cat > "$INSTALL_MARKER" << EOF
# CNI Plugins Installation Marker
# Generated on: $(date)
# Version: $CNI_VERSION
# Configuration:
#   INSTALL_MAIN: $INSTALL_MAIN
#   INSTALL_IPAM: $INSTALL_IPAM
#   INSTALL_META: $INSTALL_META
#   INSTALL_WINDOWS: $INSTALL_WINDOWS
EOF
    echo "✓ Installation marker created: $INSTALL_MARKER"
}

# Function to verify installation
verify_installation() {
    echo ""
    echo "=== Verifying installation ==="

    # Check for required plugins
    local required_plugins="bridge loopback"
    local optional_plugins="host-local static portmap bandwidth tuning firewall"
    local missing_required=""
    local missing_optional=""

    for plugin in $required_plugins; do
        if [ -f "${CNI_BIN_DIR}/$plugin" ]; then
            echo "✓ Required plugin: $plugin"
        else
            echo "✗ Missing required plugin: $plugin"
            missing_required="$missing_required $plugin"
        fi
    done

    for plugin in $optional_plugins; do
        if [ -f "${CNI_BIN_DIR}/$plugin" ]; then
            echo "✓ Optional plugin: $plugin"
        else
            echo "- Optional plugin not installed: $plugin"
            missing_optional="$missing_optional $plugin"
        fi
    done

    # Check zun-cni specifically
    if [ -f "${CNI_BIN_DIR}/zun-cni" ]; then
        echo "✓ zun-cni plugin: installed"
    else
        echo "✗ zun-cni plugin: missing"
        missing_required="$missing_required zun-cni"
    fi

    if [ -n "$missing_required" ]; then
        echo "⚠ Warning: Missing required plugins:$missing_required"
        echo "This may cause network configuration failures"
        return 1
    fi

    return 0
}

# Main execution
main() {
    echo "Starting CNI plugins installation process..."

    # Check if installation is needed
    if check_installation_needed; then
        echo "Installation required, proceeding..."

        # Install plugins
        install_cni_plugins

        # Clean up unwanted plugins
        cleanup_plugins

        # Create zun-cni plugin
        create_zun_cni

        # Finalize installation
        finalize_installation

        echo "✓ CNI plugins installation completed"
    else
        echo "✓ CNI plugins already up to date, skipping installation"
    fi

    # Always verify installation
    if verify_installation; then
        echo "✓ Installation verification successful"
    else
        echo "⚠ Installation verification had warnings"
    fi

    # Display final status
    echo ""
    echo "=== Installation Summary ==="
    echo "- Version: $CNI_VERSION"
    echo "- Location: $CNI_BIN_DIR"
    echo "- Total plugins: $(ls -1 ${CNI_BIN_DIR}/ 2>/dev/null | grep -v '^\.' | wc -l)"
    echo "- zun-cni status: $([ -f "${CNI_BIN_DIR}/zun-cni" ] && echo "installed" || echo "missing")"
    echo "- Configuration:"
    echo "  * Main plugins: ${INSTALL_MAIN}"
    echo "  * IPAM plugins: ${INSTALL_IPAM}"
    echo "  * Meta plugins: ${INSTALL_META}"
    echo "  * Windows plugins: ${INSTALL_WINDOWS}"

    echo ""
    echo "Installed plugins:"
    ls -la "${CNI_BIN_DIR}/" | grep -v '^\.'
}

# Execute main function
main