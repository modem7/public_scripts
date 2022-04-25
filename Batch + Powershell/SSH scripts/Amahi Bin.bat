@echo off
set TERM=xterm
ssh -t alex@192.168.0.254 "sudo greyhole -a"