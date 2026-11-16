<#
  MATMAS - archive collected source files on the Secure Agent where they landed.
  Called by the Command Task step "CT_ArchiveSource" of tf_MATMAS_ORCHESTRATOR, whose
  Runtime Environment is taken from the config row, so it always runs on the right agent.

  Moves files in -SourceDir matching -FilePattern whose last write time is BEFORE the run
  started (-RunId, yyyyMMddHHmmss UTC) to -ArchiveDir as <name>_<RunId><ext>.
  Files that arrived after the run started are left for the next run.

  Install once per Secure Agent machine (same path everywhere), e.g.
  C:\Informatica\scripts\matmas_archive_source.ps1  (+ the .cmd wrapper next to it)
#>
param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$FilePattern,
    [Parameter(Mandatory = $true)][string]$ArchiveDir,
    [Parameter(Mandatory = $true)][string]$RunId
)
$ErrorActionPreference = 'Stop'
$runStartUtc = [datetime]::ParseExact($RunId, 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture,
                                      [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
if (-not (Test-Path -LiteralPath $SourceDir)) { Write-Output "source folder not found: $SourceDir"; exit 2 }
if (-not (Test-Path -LiteralPath $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }

$moved = 0
Get-ChildItem -LiteralPath $SourceDir -Filter $FilePattern -File |
    Where-Object { $_.LastWriteTimeUtc -lt $runStartUtc } |
    ForEach-Object {
        $dest = Join-Path $ArchiveDir ("{0}_{1}{2}" -f $_.BaseName, $RunId, $_.Extension)
        Move-Item -LiteralPath $_.FullName -Destination $dest -Force
        Write-Output "archived $($_.FullName) -> $dest"
        $moved++
    }
Write-Output "files archived: $moved"
exit 0
