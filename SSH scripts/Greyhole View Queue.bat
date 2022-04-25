@echo off

set TERM=xterm
wt ssh -t alex@192.168.0.254 "clear && watch -d greyhole --view-queue"