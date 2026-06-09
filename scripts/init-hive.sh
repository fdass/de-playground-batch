#!/bin/bash
set -e

export HIVE_CONF_DIR=/opt/hive/conf

if [ -d /hive-custom-conf ]; then
  find /hive-custom-conf -type f -exec ln -sfn {} /opt/hive/conf/ \;
fi

export HADOOP_CONF_DIR=/opt/hive/conf

echo "Initializing Metastore schema..."
/opt/hive/bin/schematool -dbType postgres -initOrUpgradeSchema
