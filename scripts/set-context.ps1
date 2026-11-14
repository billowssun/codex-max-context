<#
.SYNOPSIS
  Raise the Codex context window (model_context_window in config.toml).

.DESCRIPTION
  Works with Windows PowerShell 5.1 and PowerShell 7+ on Windows, macOS and Linux.
  Only edits the top-level `model_context_window` key in $CODEX_HOME/config.toml
  (default ~/.codex/config.toml). Every change is backed up first as
  config.toml.ctxbak-<timestamp>. models_cache.json is only read, never written.

.EXAMPLE
  ./set-context.ps1 -Status          # show current settings and limits, change nothing
  ./set-context.ps1                  # set model_context_window = 1000000
  ./set-context.ps1 -Value 600000    # set a custom value
  ./set-context.ps1 -DryRun          # preview the change
  ./set-context.ps1 -Restore         # undo the most recent change
#>
[CmdletBinding()]
param(
  [ValidateRange(1000, 100000000)][int]$Value = 1000000,
  [string]$Model,
  [switch]$Status,
  [switch]$Restore,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$cfg   = Join-Path $codexHome 'config.toml'
$cache = Join-Path $codexHome 'models_cache.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$backupPrefix = 'config.toml.ctxbak-'

function Read-Text([string]$path) {
  if (Test-Path -LiteralPath $path) { return [IO.File]::ReadAllText($path) }
  return ''
}

# Value of a key that sits before the first [section] header.
function Get-TopLevel([string]$text, [string]$key) {
  foreach ($line in ($text -split "\r?\n")) {
    if ($line -match '^\s*\[') { break }
    if ($line -match ('^\s*' + [regex]::Escape($key) + '\s*=\s*(.+?)\s*(#.*)?$')) {
      return $Matches[1].Trim().Trim('"', "'")
    }
  }
  return $null
}

# Limits Codex has cached for a model. Parsed with regex because the file can
# contain JSON that ConvertFrom-Json in PowerShell 5.1 rejects.
function Get-ModelLimits([string]$model) {
  $json = Read-Text $cache
  if (-not $json -or -not $model) { return $null }
  $m = [regex]::Match($json, '"slug"\s*:\s*"' + [regex]::Escape($model) + '"')
  if (-not $m.Success) { return $null }
  $rest = $json.Substring($m.Index + $m.Length)
  $next = [regex]::Match($rest, '"slug"\s*:')
  if ($next.Success) { $rest = $rest.Substring(0, $next.Index) }
  $get = {
    param($k)
    $r = [regex]::Match($rest, '"' + $k + '"\s*:\s*(\d+)')
    if ($r.Success) { [long]$r.Groups[1].Value } else { $null }
  }
  return [pscustomobject]@{
    Default = & $get 'context_window'
    Max     = & $get 'max_context_window'
    Percent = & $get 'effective_context_window_percent'
  }
}

function Format-K($n) { if ($null -eq $n) { 'unknown' } else { '{0:N0} (~{1}K)' -f $n, [math]::Round($n / 1000) } }

function Get-Effective($setting, $limits) {
  if (-not $limits) { return $null }
  $window = if ($setting) { [long]$setting } elseif ($limits.Default) { $limits.Default } else { return $null }
  if ($limits.Max -and $window -gt $limits.Max) { $window = $limits.Max }
  $pct = if ($limits.Percent) { $limits.Percent } else { 100 }
  return [long][math]::Floor($window * $pct / 100)
}

$text = Read-Text $cfg
if (-not $Model) { $Model = Get-TopLevel $text 'model' }
$limits = Get-ModelLimits $Model
$current = Get-TopLevel $text 'model_context_window'

Write-Host "Codex home         : $codexHome"
Write-Host "Config file        : $cfg $(if (-not (Test-Path -LiteralPath $cfg)) { '(does not exist yet)' })"
Write-Host "Model              : $(if ($Model) { $Model } else { 'not set in config (Codex default)' })"
Write-Host "model_context_window: $(if ($current) { $current } else { 'not set' })"
if ($limits) {
  Write-Host "Cached limits      : default $(Format-K $limits.Default), max $(Format-K $limits.Max), usable $($limits.Percent)%"
  Write-Host "Usable right now   : $(Format-K (Get-Effective $current $limits))"
} else {
  Write-Host "Cached limits      : not found (open Codex once so it downloads models_cache.json, or pass -Model)"
}

if ($Status) { return }

if ($Restore) {
  $latest = Get-ChildItem -LiteralPath $codexHome -Filter "$backupPrefix*" -File -ErrorAction SilentlyContinue |
            Sort-Object Name | Select-Object -Last 1
  if (-not $latest) { throw "No backup ($backupPrefix*) found in $codexHome. Nothing to restore." }
  if ($DryRun) { Write-Host "`n[dry run] Would restore $($latest.FullName)"; return }
  Copy-Item -LiteralPath $latest.FullName -Destination $cfg -Force
  Remove-Item -LiteralPath $latest.FullName
  Write-Host "`nRestored config.toml from $($latest.Name)."
  Write-Host 'Quit Codex completely and reopen it for this to take effect.'
  return
}

# Build the new file: drop any top-level model_context_window lines, then put the
# new one right after the top-level `model =` line (or at the very top).
$nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
$newLine = "model_context_window = $Value"
$out = New-Object System.Collections.Generic.List[string]
$inSection = $false; $inserted = $false
if ($text -ne '') {
  foreach ($line in ($text -split "\r?\n")) {
    if (-not $inSection -and $line -match '^\s*\[') { $inSection = $true }
    if (-not $inSection -and $line -match '^\s*model_context_window\s*=') { continue }
    $out.Add($line)
    if (-not $inSection -and -not $inserted -and $line -match '^\s*model\s*=') { $out.Add($newLine); $inserted = $true }
  }
}
if (-not $inserted) { $out.Insert(0, $newLine) }
if ($text -eq '') { $out.Add('') }
$newText = [string]::Join($nl, $out)

$after = Get-Effective $Value $limits
if ($DryRun) {
  Write-Host "`n[dry run] Would write: $newLine"
  Write-Host "[dry run] Usable after restart: $(Format-K $after)"
  return
}

if (-not (Test-Path -LiteralPath $codexHome)) { New-Item -ItemType Directory -Path $codexHome -Force | Out-Null }
$backup = $null
if (Test-Path -LiteralPath $cfg) {
  $backup = Join-Path $codexHome ($backupPrefix + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  Copy-Item -LiteralPath $cfg -Destination $backup
}
[IO.File]::WriteAllText($cfg, $newText, $utf8NoBom)

Write-Host "`nDone: $newLine"
if ($backup) { Write-Host "Backup             : $backup" }
Write-Host "Usable after restart: $(Format-K $after)"
if ($limits -and $limits.Max -and $Value -gt $limits.Max) {
  Write-Host "Note: Codex caps $Model at $(Format-K $limits.Max), so the window stops there; the rest is reserved by Codex."
}
Write-Host 'Next: quit Codex completely, reopen it and start a NEW conversation.'
