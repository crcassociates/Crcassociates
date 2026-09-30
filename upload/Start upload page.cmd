@echo off
rem Starts the time card upload page on this computer and opens it in the browser.
rem Keep this window open while you use the page; close it to stop.
title CRC Associates - Upload time cards
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
if errorlevel 1 pause
