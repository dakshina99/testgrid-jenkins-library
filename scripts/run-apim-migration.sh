#!/bin/bash
# -------------------------------------------------------------------------------------
# Copyright (c) 2025 WSO2 LLC. (http://www.wso2.org) All Rights Reserved.
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# --------------------------------------------------------------------------------------
set -e

# === Configuration ===
APIM_VERSION="4.5.0"
SOURCE_VERSION="3.2.0"
MIGRATION_ZIP="wso2am-migration-4.5.0.7.zip"
APIM_ZIP="wso2am-${APIM_VERSION}.zip"
MIGRATION_DIR_NAME="wso2am-migration-4.5.0.7"
WORK_DIR="${WORKSPACE:-$(pwd)}"
APIM_HOME="${WORK_DIR}/wso2am-${APIM_VERSION}"
LOG_FILE="$APIM_HOME/repository/logs/wso2carbon.log"
POLICY_FILE="$APIM_HOME/repository/resources/governance/default-policies/wso2_api_mgt_best_practices.yaml"
CONFIG_FILE="${APIM_HOME}/repository/conf/deployment.toml"
MIGRATION_RESOURCES_DIR="${WORK_DIR}/${MIGRATION_DIR_NAME}"

# === Step 1: Unpack APIM and migration resources ===
echo "Unpacking WSO2 API Manager..."
unzip -o -q "${WORK_DIR}/${APIM_ZIP}" -d "$WORK_DIR"

echo "Downloading and unpacking migration resources..."
aws s3 cp "s3://integration-testgrid-resources/apim-migration-resources/migrate-to-latest/${MIGRATION_ZIP}" "${WORK_DIR}/"
unzip -q "${WORK_DIR}/${MIGRATION_ZIP}" -d "$WORK_DIR"

# === Step 2: Copy migration resources and JARs ===
echo "Copying migration-resources..."
cp -r "${MIGRATION_RESOURCES_DIR}/migration-resources" "$APIM_HOME/"

echo "Copying migration .jar files..."
cp "${MIGRATION_RESOURCES_DIR}/dropins/"*.jar "$APIM_HOME/repository/components/dropins/"

# === Step 3: Update deployment.toml ===
echo "Configuring deployment.toml..."

# Remove existing [indexing] and [apim.devportal] blocks if present
awk '
BEGIN {skip=0}
/^\[indexing\]/ {skip=1}
/^\[apim\.devportal\]/ {skip=1}
skip && /^\[.*\]/ && $0 !~ /^\[indexing\]/ && $0 !~ /^\[apim\.devportal\]/ {skip=0}
!skip {print}
' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

# Append required block
cat <<'EOF' >> "$CONFIG_FILE"

[indexing]
indexing = 10

[apim.devportal]
enable_cross_tenant_subscriptions = true
enable_application_sharing = true
application_sharing_type = "default"
display_multiple_versions = true

[apim.policy]
enable_api_level_policies = true
EOF

# Update gateway environment name
sed -i.bak '/\[\[apim.gateway.environment\]\]/{
    N
    s/name = "Default"/name = "Production and Sandbox"/
}' "$CONFIG_FILE"

# Update gateway labels
sed -i 's/\[apim.sync_runtime_artifacts.gateway\]/[apim.sync_runtime_artifacts.gateway]/' "$CONFIG_FILE"
sed -i 's/gateway_labels =\["Default"\]/gateway_labels =["Default", "Production and Sandbox"]/' "$CONFIG_FILE"

# Set create_admin_account to false
sed -i.bak '/\[super_admin\]/,/\[.*\]/ s/create_admin_account *= *true/create_admin_account = false/' "$CONFIG_FILE"

# Display the config file
echo "Updated deployment.toml:"
cat "$CONFIG_FILE"

export JAVA_HOME="/usr/lib/jvm/jdk-11.0.21_9/"
export PATH="$JAVA_HOME/bin:$PATH"

echo $JAVA_HOME
java -version

ls -l /usr/lib/jvm/jdk-11.0.21_9/

# === Step 5: Run migration ===
echo "Starting APIM migration..."
sudo chmod 755 $APIM_HOME/bin/api-manager.sh
#nohup sh "$APIM_HOME/bin/api-manager.sh" -Dmigrate -DmigrateFromVersion="$SOURCE_VERSION" > "$LOG_FILE" 2>&1 &
sudo sh "$APIM_HOME/bin/api-manager.sh" -Dmigrate -DmigrateFromVersion="$SOURCE_VERSION"

#echo "Waiting for server to start..."
#while [ ! -f "$LOG_FILE" ]; do sleep 2; done
#
#until grep -q "StartupFinalizerServiceComponent WSO2 Carbon started in" "$LOG_FILE"; do sleep 5; done
#echo "Migration complete."
#
## === Step 6: Stop server ===
#echo "Stopping server..."
#sh "$APIM_HOME/bin/api-manager.sh" --stop
#sleep 10
#
## === Step 7: Enable re-indexing ===
#echo "Updating indexing config for re_indexing..."
#if grep -q "^\[indexing\]" "$CONFIG_FILE"; then
#    sed -i.bak '/^\[indexing\]/,/^\[/{s/^indexing *=.*/re_indexing = 1/}' "$CONFIG_FILE"
#    echo "Re-indexing enabled."
#else
#    echo "[indexing] section not found."
#fi
#
## === Step 9: Remove the added migration related files ===
#echo "Cleaning up migration resources..."
#rm -rf "${APIM_HOME}/migration-resources"
#rm -f "${APIM_HOME}/repository/components/dropins/org.wso2.carbon.apimgt.migrate.client"*.jar
#
## === Step 10: Zip the product again ===
#echo "Zipping the migrated WSO2 API Manager..."
#rm -rf $APIM_ZIP
#zip -r -q "${WORK_DIR}/${APIM_ZIP}" "$APIM_HOME"
#
## Display the whole log file
#tail -f "$LOG_FILE"
