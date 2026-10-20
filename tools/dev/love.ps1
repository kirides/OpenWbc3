# Runs the game with lovec (console LÖVE) from the repository root, with a timeout, and prints
# its output. Meant for scripted checks and screenshots by developers and coding agents.
#
#   pwsh tools/dev/love.ps1 [-Timeout <s>] [-Tail <n>] -- <game args...>
#
#   pwsh tools/dev/love.ps1 -- --selftest
#   pwsh tools/dev/love.ps1 -Timeout 60 -- --scenario Bridges --shot shots/bridges.png --after 5
#
# Arguments after `--` go to the game unchanged (quoting is preserved, so `--at 2 "S:openMenu()"`
# works). The process is killed after -Timeout seconds (LÖVE's error screen waits for input, so a
# crash with a window would otherwise hang). Exit code: the game's, or 124 on timeout.

# no param() block: PowerShell's binder would try to interpret the game's `--options`
$Timeout, $Tail = 120, 0
$GameArgs = [System.Collections.Generic.List[string]]::new()
$own = $true
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($own -and $a -eq "-Timeout") { $Timeout = [int]$args[++$i] }
    elseif ($own -and $a -eq "-Tail") { $Tail = [int]$args[++$i] }
    elseif ($own -and $a -eq "--") { $own = $false }
    else { $own = $false; $GameArgs.Add($a) }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$lovec = (Get-Command lovec -ErrorAction SilentlyContinue).Source
if (-not $lovec) { $lovec = Join-Path $env:ProgramFiles "LOVE\lovec.exe" }
if (-not (Test-Path $lovec)) { Write-Error "lovec.exe not found (install a LÖVE 12.0 pre-release)"; exit 127 }

$psi = [System.Diagnostics.ProcessStartInfo]::new($lovec)
$psi.WorkingDirectory = $root
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.ArgumentList.Add((Join-Path $root "game"))
foreach ($a in $GameArgs) { $psi.ArgumentList.Add($a) }

# screenshot targets: create the folder so the game can write the file
for ($i = 0; $i -lt $GameArgs.Count - 1; $i++) {
    if ($GameArgs[$i] -eq "--shot") {
        $dir = Split-Path -Parent ([System.IO.Path]::GetFullPath($GameArgs[$i + 1], $root))
        if ($dir) { New-Item -ItemType Directory -Force $dir | Out-Null }
    }
}

$p = [System.Diagnostics.Process]::Start($psi)
$out = $p.StandardOutput.ReadToEndAsync()
$err = $p.StandardError.ReadToEndAsync()
$code = 0
if ($p.WaitForExit($Timeout * 1000)) {
    $p.WaitForExit()
    $code = $p.ExitCode
} else {
    $p.Kill($true)
    $code = 124
}
$text = ($out.Result + $err.Result) -split "`r?`n" | Where-Object { $_ -ne "" }
if ($Tail -gt 0) { $text = $text | Select-Object -Last $Tail }
$text | ForEach-Object { Write-Output $_ }
if ($code -eq 124) { Write-Output "[love.ps1] TIMEOUT after $Timeout s, process killed" }
exit $code
