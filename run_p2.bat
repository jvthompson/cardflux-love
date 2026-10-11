@echo off
rem Launches a second Cardflux instance as "player 2" for local multiplayer testing.
rem Uses a separate save folder (identity cardflux_p2), so settings, profile name,
rem avatar and server login don't collide with the main instance.
rem   run_p2.bat          start the app
rem   run_p2.bat console  start the app with a console window for print/log output

setlocal
set "GAME_DIR=%~dp0."
set "IDENTITY=cardflux_p2"

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

if /i "%~1"=="console" (
  "%LOVE_DIR%\lovec.exe" "%GAME_DIR%" --identity %IDENTITY%
  exit /b %ERRORLEVEL%
)

start "" "%LOVE_DIR%\love.exe" "%GAME_DIR%" --identity %IDENTITY%
