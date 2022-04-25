#!/bin/sh
# This script will backup InfluxDB
docker exec GrafanaDB influxd backup -portable /dbbackup/ &
echo "Backup complete"