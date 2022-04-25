#!/bin/sh
# This script will create a Teleport backup to a directory that it is run in.
# Change to mapped directory
cd /backup
# Run Backup
pihole -a -t &
# Record the process id and wait
process_id=$!
wait $process_id
echo "Backup complete with status $?"