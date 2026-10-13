@echo off
rem Starts the NexLoot companion app in the background (golden N in the system tray).
rem Runs hidden via conhost --headless, so Windows 11 shows no terminal window in the taskbar.
set "NEXPS=%~dp0NexLootCompanion.ps1"
if not exist "%SystemRoot%\System32\conhost.exe" goto plain
start "" "%SystemRoot%\System32\conhost.exe" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%NEXPS%"
goto :eof
:plain
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%NEXPS%"
