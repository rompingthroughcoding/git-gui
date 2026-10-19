@echo off
set PATH=C:\Program Files\Git\usr\bin;C:\Program Files\Git\ucrt64\bin;%PATH%
if "%~1"=="" (
    cd /d %USERPROFILE%
    start "" "C:\Program Files\Git\ucrt64\bin\wish.exe" "%~dp0git-gui.sh"
) else (
    start "" "C:\Program Files\Git\ucrt64\bin\wish.exe" "%~dp0git-gui.sh" %*
)
