@echo off
rem Copy Desktop scripts to Github

rem Copy Github Scripts
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Git Scripts" "project_work_update.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Git Scripts" "git_docker_update.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Git Scripts" "git_scripts_update.bat"

rem Copy SSH scripts
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\SSH scripts" "alex chown oldhd desktopcontent.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\SSH scripts" "Amahi Bin.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\SSH scripts" "Amahi Incomplete.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\SSH scripts" "ArrSambaDockRestart.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\SSH scripts" "borgmatic_update_scripts.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\SSH scripts" "CIFS Samba mnt fix.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\SSH scripts" "Greyhole.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\SSH scripts" "IPMIFan.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\SSH scripts" "MemspoolGreyhole.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\SSH scripts" "ProxmoxAPTUpdate.bat"

rem Copy General Scripts
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Desktop Scripts" "medialist.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Desktop Scripts" "iDrive_service.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Desktop Scripts" "shutdownprompt.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Desktop Scripts" "hdamount.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Desktop Scripts" "closewaterfox.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Desktop Scripts" "coretemp download.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Desktop Scripts" "delplexbkupfiles.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Desktop Scripts" "audio.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Desktop Scripts" "delete network shares.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Desktop Scripts" "startlogitech.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Desktop Scripts" "deldownloads.bat"
robocopy "C:\Users\Alex\Desktop" "G:\Git Projects\Scripts\Desktop Scripts" "greyhole commands.txt"



rem Copy Github Repo to W:\Scripts
robocopy "G:\Git Projects\Scripts" W:\Scripts /mir /XD "G:\Git Projects\Scripts\.git"

rem Update Git
cd /D "G:\Git Projects\Scripts"
git pull
git add .
echo "Scripted Commit"
git commit -S -am "Scripted Commit"
git push