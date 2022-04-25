@echo off
set TERM=xterm
ssh -t alex@192.168.0.254 "sudo rm -rf /var/hda/files/drives/drive14/newsgroups/incomplete/*"