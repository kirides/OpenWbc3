# Golden-master check (docs/data-driven/07-verification-legal.md 7.1): runs tools/dev/snapshot.lua at a baseline commit (in
# a git worktree next to the repository, created on first use) and at the working tree, and prints the differences.
#
#   pwsh tools/dev/golden.ps1 -Baseline <commit>        # empty output = nothing moved
#   pwsh tools/dev/golden.ps1 -Baseline HEAD -Keep      # keep the snapshot files (they are derived from the install)
#
# The snapshot script of the *working tree* is used for both runs, so it must only use API that exists at both commits.
param([Parameter(Mandatory)][string]$Baseline, [switch]$Keep, [switch]$Spells, [switch]$Quick, [string[]]$Sims = @("Bridges"))
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$sha = (git -C $root rev-parse --short $Baseline).Trim()
$tree = Join-Path (Split-Path $root -Parent) "openwbc3-golden-$sha"
if (-not (Test-Path $tree)) { git -C $root worktree add --detach $tree $sha | Out-Null }
if ($Quick) { $env:WBC3_SNAP_QUICK = "1" }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "openwbc3-golden"
New-Item -ItemType Directory -Force $tmp | Out-Null
$script = Join-Path $root "tools\dev\snapshot.lua"
$a = Join-Path $tmp "base-$sha.txt"
$b = Join-Path $tmp "work.txt"
$o = & (Join-Path $tree "tools\dev\love.ps1") -Timeout 900 -- --selftest --lua $script $a
if (-not ($o -match "snapshot lines")) { $o | Select-Object -Last 12; Write-Error "golden: the baseline snapshot failed"; exit 2 }
$o = & (Join-Path $root "tools\dev\love.ps1") -Timeout 900 -- --selftest --lua $script $b
if (-not ($o -match "snapshot lines")) { $o | Select-Object -Last 12; Write-Error "golden: the working tree snapshot failed"; exit 2 }
# battle simulations: the per-minute summary lines must be identical too (they depend on every rule)
foreach ($map in $Sims) {
    foreach ($pair in @(@($tree, $a), @($root, $b))) {
        & (Join-Path $pair[0] "tools\dev\love.ps1") -Timeout 600 -- --selftest --sim $map | Where-Object { $_ -match "t=\d+min" } | Add-Content $pair[1]
    }
}
# the spells: one digest per cast of every spell at every success level (tools/dev/spellsnap.lua, ~20 s each run)
if ($Spells) {
    $spellScript = Join-Path $root "tools\dev\spellsnap.lua"
    foreach ($pair in @(@($tree, $a), @($root, $b))) {
        $tmpFile = "$($pair[1]).spells"
        & (Join-Path $pair[0] "tools\dev\love.ps1") -Timeout 900 -- --selftest --lua $spellScript $tmpFile | Select-Object -Last 1
        if (Test-Path $tmpFile) { Get-Content $tmpFile | Add-Content $pair[1]; Remove-Item $tmpFile }
    }
}
if (-not (Test-Path $a) -or -not (Test-Path $b)) { Write-Error "golden: a snapshot was not written (see the output above)"; exit 2 }
$diff = Compare-Object (Get-Content $a) (Get-Content $b)
if ($diff) { $diff | Select-Object -First 80 | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }; Write-Output "golden: $($diff.Count) differing lines (baseline $sha)" }
else { Write-Output "golden: identical to $sha" }
if (-not $Keep) { Remove-Item $a, $b }
exit ($diff ? 1 : 0)
