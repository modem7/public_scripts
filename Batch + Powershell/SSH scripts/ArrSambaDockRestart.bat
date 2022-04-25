@echo off
set TERM=xterm
ssh -t alex@192.168.0.254 "sudo docker container restart Sonarr Radarr Tdarr Tdarr-node Bazarr Ombi Overseer Plex"