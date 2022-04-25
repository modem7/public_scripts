@echo off
set TERM=xterm
ssh -t alex@192.168.0.254 "echo "Deleting /var/spool/greyhole.bak" && sudo rm -rfv /var/spool/greyhole.bak && echo "Moving /var/spool/greyhole to .bak" && sudo mv /var/spool/greyhole /var/spool/greyhole.bak && sudo mkdir -p /var/spool/greyhole && sudo chmod 777 /var/spool/greyhole && sudo /usr/bin/greyhole --create-mem-spool && echo "Restarting Greyhole" && sudo service greyhole restart && sudo greyhole --fsck && sudo rm -rfv /var/spool/greyhole.bak"

echo Complete. Press any key to exit
pause > nul