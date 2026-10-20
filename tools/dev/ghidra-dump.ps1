# Dumps the original game binary with headless Ghidra into greppable text files (tools/ghidra/DumpProgram.java):
# decompiled C per function, an index with sizes and callers, and every string with the functions using it.
# The way to verify behaviour: grep the dump, cite addresses (FUN_0042ace0) in comments and docs.
#
#   pwsh tools/dev/ghidra-dump.ps1 -Ghidra <ghidra dir> [-Exe <game exe>] [-Out <dir>]
#   pwsh tools/dev/ghidra-dump.ps1 -Ghidra <ghidra dir> -Project <dir\name.gpr> -Program "<name>" [-Out <dir>]
#
# Without -Project the exe is imported into a temporary project and auto-analysed first (about 10-20 minutes).
# With -Project an existing analysed project is copied (Ghidra locks an open project) and dumped read-only.
# -Exe defaults to "Battlecry III.exe" in the game folder found like the game does (WBC3_DIR, then the GOG path);
# the dump is only comparable with the docs for the 1.04 release (MD5 printed at the start of the log).
# -Out defaults to %LOCALAPPDATA%\openwbc3\ghidra-dump (outside the repository: the dump is derived from the binary).
param(
    [Parameter(Mandatory)] [string] $Ghidra,
    [string] $Exe,
    [string] $Project,
    [string] $Program,
    [string] $Out = (Join-Path $env:LOCALAPPDATA "openwbc3\ghidra-dump")
)
$ErrorActionPreference = "Stop"
$headless = Join-Path $Ghidra "support\analyzeHeadless.bat"
if (-not (Test-Path $headless)) { Write-Error "analyzeHeadless.bat not found under $Ghidra"; exit 1 }
$scripts = (Resolve-Path (Join-Path $PSScriptRoot "..\ghidra")).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("openwbc3-ghidra-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $work, $Out | Out-Null
$log = Join-Path $Out "dump.log"
try {
    if ($Project) {
        $gpr = Get-Item $Project
        $name = [System.IO.Path]::GetFileNameWithoutExtension($gpr.Name)
        Copy-Item $gpr.FullName $work
        Copy-Item (Join-Path $gpr.DirectoryName "$name.rep") $work -Recurse
        if (-not $Program) { Write-Error "-Program is required with -Project"; exit 1 }
        & $headless $work $name -process $Program -readOnly -noanalysis -scriptPath $scripts `
            -postScript DumpProgram.java $Out *> $log
    } else {
        if (-not $Exe) {
            $dirs = @($env:WBC3_DIR, "C:\GOG Games\Warlords Battlecry 3", "${env:ProgramFiles(x86)}\GOG Galaxy\Games\Warlords Battlecry 3")
            foreach ($d in $dirs) {
                if ($d -and (Test-Path (Join-Path $d "Battlecry III.exe"))) { $Exe = Join-Path $d "Battlecry III.exe"; break }
            }
            if (-not $Exe) { Write-Error "game exe not found: pass -Exe"; exit 1 }
        }
        & $headless $work dump -import $Exe -scriptPath $scripts -postScript DumpProgram.java $Out -deleteProject *> $log
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Select-String -Path $log -Pattern "MD5 |created |DONE |ERROR" | ForEach-Object { $_.Line }
