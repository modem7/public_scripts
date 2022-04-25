@echo off
cd /D "L:\"
git pull
git add .
echo "Scripted Commit"
git commit -S -am "Scripted Commit"
git push