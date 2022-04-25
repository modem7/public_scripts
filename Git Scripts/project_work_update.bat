@echo off
cd /D "G:\Git Projects\project_work"
git pull
git add .
echo "Scripted Commit"
git commit -S -am "Scripted Commit"
git push