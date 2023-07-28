#!/bin/bash
# update all containers

# list of container ids we need to iterate through
containers=$(pct list | tail -n +2 | cut -f1 -d' ')

function update_container() {
  container=$1
  echo "[Info] Updating $container"
  # to chain commands within one exec we will need to wrap them in bash
  pct exec $container -- bash -c "apt-get update && apt-get upgrade -y && apt-get autoremove -y"
}

for container in $containers
do
  status=`pct status $container`
  if [ "$status" == "status: stopped" ]; then
    echo [Info] Starting $container
    pct start $container
    echo [Info] Sleeping 5 seconds
    sleep 5
    update_container $container
    echo [Info] Shutting down $container
    pct shutdown $container &
  elif [ "$status" == "status: running" ]; then
    update_container $container
  fi
done; wait
