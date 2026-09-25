@echo off
set PATH=C:\Program Files\Git\usr\bin;C:\Program Files\Git\mingw64\bin;%PATH%
start "" "C:\Program Files\Git\mingw64\bin\wish.exe" "%~dp0git-gui-master.tcl" -- %*
