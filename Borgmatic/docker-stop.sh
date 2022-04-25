#!/bin/sh
# docker stop script

docker container stop -t 60 $(docker ps -q -f "label=backup")