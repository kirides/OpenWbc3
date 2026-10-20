# Runs the Lua language server's static check over the repository (settings: .luarc.json at the root) and prints the
# diagnostics, a summary per file and per kind. Exit code 1 when there are more than -Max diagnostics (default 0).
#
#   pwsh tools/dev/luals.ps1                     # whole repository
#   pwsh tools/dev/luals.ps1 -Path game/src/ui   # only report files under a folder (the whole tree is still loaded)
#   pwsh tools/dev/luals.ps1 -Summary            # counts only
#
# Needs lua-language-server on PATH (https://luals.github.io, e.g. `scoop install lua-language-server`).
param(
    [string] $Path = "",
    [int] $Max = 0,
    [switch] $Summary
)
$ErrorActionPreference = "Stop"
$luals = (Get-Command lua-language-server -ErrorAction SilentlyContinue).Source
if (-not $luals) { Write-Error "lua-language-server not found on PATH"; exit 127 }
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("openwbc3-luals-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    $out = Join-Path $tmp "check.json"
    & $luals --check=$root --checklevel=Information --check_format=json --check_out_path=$out --logpath=$tmp *> $null
    $found = @()
    if (Test-Path $out) {
        $json = Get-Content $out -Raw | ConvertFrom-Json -AsHashtable
        foreach ($uri in $json.Keys) {
            # file:///e%3A/dir/file.lua -> e:/dir/file.lua (the server writes Windows drive letters in lower case)
            $file = [uri]::UnescapeDataString(([uri]$uri).AbsolutePath) -replace "^/([A-Za-z]:)", '$1'
            $rel = [System.IO.Path]::GetRelativePath($root, $file) -replace "\\", "/"
            if ($Path -and -not $rel.StartsWith(($Path -replace "\\", "/").TrimEnd("/") + "/") -and $rel -ne $Path) { continue }
            foreach ($d in $json[$uri]) {
                $found += [pscustomobject]@{ File = $rel; Line = $d.range.start.line + 1; Code = $d.code
                                             Message = ($d.message -split "`n")[0] }
            }
        }
    }
    if (-not $Summary) {
        $found | Sort-Object File, Line | ForEach-Object { "{0}:{1}: [{2}] {3}" -f $_.File, $_.Line, $_.Code, $_.Message }
    }
    $found | Group-Object File | Sort-Object Count -Descending | Select-Object -First 20 |
        ForEach-Object { "{0,5} {1}" -f $_.Count, $_.Name }
    $found | Group-Object Code | Sort-Object Count -Descending | ForEach-Object { "{0,5} [{1}]" -f $_.Count, $_.Name }
    "luals: $($found.Count) diagnostics (allowed $Max)"
    exit ($found.Count -gt $Max ? 1 : 0)
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
