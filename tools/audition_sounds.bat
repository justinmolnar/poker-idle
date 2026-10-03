@echo off
rem Double-click to audition the sound candidates: starts the local server
rem (tools/audition_sounds.py) and opens the page in your browser. Close
rem this window to stop it. Picks save to assets\audio\raw\candidates\picks.json.
cd /d "%~dp0.."
where python >nul 2>nul
if %errorlevel%==0 (
    python tools\audition_sounds.py
) else (
    py tools\audition_sounds.py
)
if errorlevel 1 pause
