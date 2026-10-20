@echo off
rem Converts original Warlords Battlecry III assets that LOVE cannot read
rem directly (Bink videos, optionally sounds) into game\converted\.
rem Requires ffmpeg (with libtheora + libvorbis) on PATH or via --ffmpeg.
rem
rem Usage: tools\convert.bat [--data "<game dir>"] [--ffmpeg <ffmpeg.exe>] [--audio] [--no-video]

setlocal
set "ROOT=%~dp0.."
set "LOVEC=lovec"
where lovec >nul 2>nul || set "LOVEC=%ProgramFiles%\LOVE\lovec.exe"
"%LOVEC%" "%ROOT%\game" --convert %*
