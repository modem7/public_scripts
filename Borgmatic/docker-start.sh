#!/bin/sh
# docker start script

docker container start $(docker container ls -aq)