wget http://www.alcpu.com/CoreTemp/Core-Temp-setup.exe -O %UserProfile%\Desktop\coretemp.exe

%UserProfile%\Desktop\coretemp.exe /sp /silent /closeapplications

START C:\"Program Files"\"Core Temp"\"Core Temp.exe" 

del %UserProfile%\Desktop\coretemp.exe
del "%UserProfile%\Desktop\Core Temp.lnk"
del "%UserProfile%\Desktop\Goodgame Empire.url"

exit