@echo off
rem Starts the PokeWilds dedicated server. Ctrl+C or closing this window saves and stops it.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server_launcher.ps1" %*
if errorlevel 1 pause
