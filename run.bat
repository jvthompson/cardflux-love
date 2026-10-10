@echo off
rem Launches Cardflux (LOVE port) from this folder.
rem   run.bat          start the app
rem   run.bat test     run the test suite in this console
rem   run.bat console  start the app with a console window for print/log output

setlocal
set "GAME_DIR=%~dp0."

rem Locate LOVE: standard install folders first, then PATH.
set "LOVE_DIR="
if exist "%ProgramFiles%\LOVE\love.exe" set "LOVE_DIR=%ProgramFiles%\LOVE"
if not defined LOVE_DIR if exist "%ProgramFiles(x86)%\LOVE\love.exe" set "LOVE_DIR=%ProgramFiles(x86)%\LOVE"
if not defined LOVE_DIR (
  for %%I in (love.exe) do if not "%%~$PATH:I"=="" set "LOVE_DIR=%%~dp$PATH:I"
)
if not defined LOVE_DIR (
  echo Could not find LOVE 11.5. Install it from https://love2d.org or add love.exe to PATH.
  pause
  exit /b 1
)

if /i "%~1"=="test" (
  "%LOVE_DIR%\lovec.exe" "%GAME_DIR%" --test %2
  exit /b %ERRORLEVEL%
)

if /i "%~1"=="console" (
  "%LOVE_DIR%\lovec.exe" "%GAME_DIR%"
  exit /b %ERRORLEVEL%
)

start "" "%LOVE_DIR%\love.exe" "%GAME_DIR%"
