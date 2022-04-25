@echo off
set TERM=xterm
title Proxmox
:home
cls
echo.
echo Start Ansible first, shut it down last.
echo =======================================
echo.
echo Select a task:
echo =============
echo.
echo [92m1) Start Ansible VM[0m
echo [94m2) Check VM status[0m
echo [93m3) Update VMs[0m
echo [93m4) Update Teleport VMs[0m
echo [93m5) Update Ansible VM[0m
echo [93m6) Update Everything (no Ansible shutdown)[0m
echo [96m7) Fully Automated[0m
echo [91m8) Shutdown Ansible VM[0m
echo [96m9) Ansible Git Pull
echo [94m0) Exit[0m
echo.
set /p web=Type option:
if "%web%"=="1" goto startansible
if "%web%"=="2" goto checkstatus
if "%web%"=="3" goto updatevms
if "%web%"=="4" goto updateteleport
if "%web%"=="5" goto updateansible
if "%web%"=="6" goto updateeverything
if "%web%"=="7" goto fullyautomated
if "%web%"=="8" goto shutdownansible
if "%web%"=="9" goto gitpull
if "%web%"=="0" exit
goto home

:startansible
cls
echo Starting Ansible VM
ssh -t root@192.168.0.251 "sudo /usr/sbin/qm start 1102"
cls
echo Waiting 15 seconds to allow bootup.
TIMEOUT /T 15 /NOBREAK
cls
goto home

:checkstatus
cls
echo Checking VM status
ssh -t root@192.168.0.251 "sudo /usr/sbin/qm list"
pause
cls
goto home

:updatevms
cls
echo Updating Non-Teleport VMs.
ssh -t modem7@192.168.50.102 "cd ~/ansible && export BW_SESSION="$(bw unlock --raw)" && bw sync -f && eval "$(ssh-agent -s)" && ansible-playbook plays/apt_upgrade_vm.yaml"
cls
goto home

:updateteleport
cls
echo Updating Teleport VMs.
ssh -t modem7@192.168.50.102 "cd ~/ansible && export BW_SESSION="$(bw unlock --raw)" && bw sync -f && eval "$(ssh-agent -s)" && ansible-playbook plays/apt_upgrade_teleport.yaml"
pause
cls
goto home

:updateansible
cls
echo Updating Ansible VM
ssh -t modem7@192.168.50.102 "sudo aptitude update && sudo aptitude safe-upgrade -y"
cls
goto home

:updateeverything
cls
echo Updating Everything - Ansible VM won't shut down.
echo.
echo Updating Teleport and Non-Teleport VMs.
ssh -t modem7@192.168.50.102 "cd ~/ansible && export BW_SESSION="$(bw unlock --raw)" && bw sync -f && eval "$(ssh-agent -s)" && ansible-playbook plays/apt_upgrade_teleport.yaml plays/apt_upgrade_vm.yaml"
cls
echo Updating Ansible VM
ssh -t modem7@192.168.50.102 "sudo aptitude update && sudo aptitude safe-upgrade -y"
cls
goto home

:fullyautomated
cls
echo Updating Everything
echo.
echo Starting Ansible VM
ssh -t root@192.168.0.251 "sudo /usr/sbin/qm start 1102"
cls
echo Waiting 15 seconds to allow bootup.
rem TIMEOUT /T 15 /NOBREAK
TIMEOUT /T 15
cls
echo Updating Teleport and Non-Teleport VMs.
ssh -t modem7@192.168.50.102 "cd ~/ansible && export BW_SESSION="$(bw unlock --raw)" && bw sync -f && eval "$(ssh-agent -s)" && ansible-playbook plays/apt_upgrade_teleport.yaml plays/apt_upgrade_vm.yaml"

echo Updating Ansible VM
ssh -t modem7@192.168.50.102 "sudo aptitude update && sudo aptitude safe-upgrade -y"

echo Shutting down Ansible VM
ssh -t root@192.168.0.251 "sudo /usr/sbin/qm shutdown 1102"
echo.
echo.

pause
goto home

:shutdownansible
cls
echo Shutting down Ansible VM
ssh -t root@192.168.0.251 "sudo /usr/sbin/qm shutdown 1102"
cls
goto home

:gitpull
cls
echo Pulling latest Git
ssh -t modem7@192.168.50.102 "cd ~/ansible && git pull"
pause
cls
goto home