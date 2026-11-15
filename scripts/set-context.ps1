<#
.SYNOPSIS
  Raise the Codex context window (model_context_window in config.toml).

.DESCRIPTION
  Works with Windows PowerShell 5.1 and PowerShell 7+ on Windows, macOS and Linux.
  Only edits the top-level `model_context_window` key in $CODEX_HOME/config.toml
  (default ~/.codex/config.toml). Every change records a field-level undo snapshot in
  config.toml.ctxundo-<timestamp>-<sequence>. models_cache.json is only read, never written.

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
$backupPrefix = 'config.toml.ctxundo-'

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

# Keep every unrelated byte, including line endings, unchanged.
function Get-ContextLine([string]$content) {
  $found = $null
  foreach ($match in [regex]::Matches($content, '[^\r\n]*(?:\r\n|\n|\r|$)')) {
    $line = $match.Value.TrimEnd("`r", "`n")
    if ($line -match '^\s*\[') { break }
    if ($line -match '^\s*model_context_window\s*=') {
      if ($null -ne $found) { throw 'Duplicate top-level context keys; resolve them manually first.' }
      $found = $line
    }
  }
  return $found
}

function Context-Value([string]$line) {
  if ($null -eq $line -or $line -eq '') { return '' }
  if ($line -notmatch '^\s*model_context_window\s*=\s*([0-9]+(?:_[0-9]+)*)\s*(?:#.*)?$') {
    throw 'Unsupported context value; resolve it manually first.'
  }
  return ([long]($Matches[1] -replace '_', '')).ToString()
}

function Replace-Context([string]$content, $replacement) {
  $result = New-Object System.Text.StringBuilder
  $inSection = $false; $found = $false
  foreach ($match in [regex]::Matches($content, '[^\r\n]*(?:\r\n|\n|\r|$)')) {
    if ($match.Length -eq 0) { continue }
    $raw = $match.Value
    $line = $raw.TrimEnd("`r", "`n")
    if ($line -match '^\s*\[') { $inSection = $true }
    if (-not $inSection -and $line -match '^\s*model_context_window\s*=') {
      $found = $true
      if ($null -ne $replacement) {
        [void]$result.Append($replacement)
        [void]$result.Append($raw.Substring($line.Length))
      }
    } else { [void]$result.Append($raw) }
  }
  if (-not $found -and $null -ne $replacement) {
    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    return $replacement + $newline + $result.ToString()
  }
  return $result.ToString()
}

function New-UndoRecord {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $prefix = $backupPrefix + $stamp + '-'
  $seq = 0
  $last = Get-ChildItem -LiteralPath $codexHome -Directory -Filter "$prefix*" |
    Where-Object { $_.Name -match ('^' + [regex]::Escape($prefix) + '\d{6}$') } |
    Sort-Object Name | Select-Object -Last 1
  if ($last) { $seq = [int]$last.Name.Substring($prefix.Length) + 1 }
  if ($seq -gt 999999) { throw 'Too many changes in one second; retry later.' }
  $path = Join-Path $codexHome ($prefix + $seq.ToString('D6'))
  New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
  return $path
}

# Mutating invocations cooperate across both scripts. Never remove another process's lock.
$lockPath = Join-Path $codexHome 'config.toml.ctxlock'
$locked = $false
try {
  if (-not $DryRun) {
    if (-not (Test-Path -LiteralPath $codexHome)) {
      New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    }
    try { New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null }
    catch { throw 'Another context operation is active (or left a stale ctxlock). Retry after it finishes; inspect a stale lock before removing it.' }
    $locked = $true
  }
  $existed = Test-Path -LiteralPath $cfg
  $text = Read-Text $cfg
  $line = Get-ContextLine $text
  $current = Context-Value $line

  if ($Restore) {
    $latest = Get-ChildItem -LiteralPath $codexHome -Filter "$backupPrefix*" -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^config\.toml\.ctxundo-\d{8}-\d{6}-\d{6}$' } |
      Sort-Object Name | Select-Object -Last 1
    if (-not $latest) {
      throw 'No safe undo record found. Legacy ctxbak backups cannot be restored automatically: manually recover only the context key, not the whole config.'
    }
    foreach ($file in @('before', 'existed', 'applied')) {
      if (-not (Test-Path -LiteralPath (Join-Path $latest.FullName $file) -PathType Leaf)) {
        throw 'Incomplete undo record; inspect it manually. Configuration was not changed.'
      }
    }
    $applied = (Read-Text (Join-Path $latest.FullName 'applied')).Trim()
    $wasPresent = (Read-Text (Join-Path $latest.FullName 'existed')).Trim()
    if ($applied -notmatch '^[0-9]+$' -or $wasPresent -notmatch '^[01]$') { throw 'Invalid undo record.' }
    if ($current -ne ([long]$applied).ToString()) {
      throw 'Context setting changed since installation. Nothing was restored; resolve the conflict manually.'
    }
    $before = Read-Text (Join-Path $latest.FullName 'before')
    $oldLine = Get-ContextLine $before
    $null = Context-Value $oldLine
    $newText = Replace-Context $text $oldLine
    if ($DryRun) { Write-Host "[dry run] Would undo only the context key using $($latest.Name)."; return }
    if ((Read-Text $cfg) -cne $text -or (Test-Path -LiteralPath $cfg) -ne $existed) { throw 'Config changed concurrently; retry.' }
    if ($wasPresent -eq '0' -and $newText.Length -eq 0) {
      Remove-Item -LiteralPath $cfg
    } else { [IO.File]::WriteAllText($cfg, $newText, $utf8NoBom) }
    Remove-Item -LiteralPath $latest.FullName -Recurse
    Write-Host 'Restored only model_context_window; subsequent unrelated settings were preserved.'
    Write-Host 'Quit Codex completely and reopen it for this to take effect.'
    return
  }

  if ($current -eq $Value.ToString()) { Write-Host 'Already set to this value; no change or undo record created.'; return }
  $newLine = "model_context_window = $Value"
  $newText = Replace-Context $text $newLine
  $after = Get-Effective $Value $limits
  if ($DryRun) {
    Write-Host "[dry run] Would write: $newLine"
    Write-Host "[dry run] Usable after restart: $(Format-K $after)"
    return
  }
  $backup = New-UndoRecord
  [IO.File]::WriteAllText((Join-Path $backup 'before'), $text, $utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $backup 'existed'), $(if ($existed) { '1' } else { '0' }), $utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $backup 'applied'), $Value.ToString(), $utf8NoBom)
  if ((Read-Text $cfg) -cne $text -or (Test-Path -LiteralPath $cfg) -ne $existed) {
    Remove-Item -LiteralPath $backup -Recurse
    throw 'Config changed concurrently; retry.'
  }
  [IO.File]::WriteAllText($cfg, $newText, $utf8NoBom)
  Write-Host "Done: $newLine"
  Write-Host "Undo record        : $backup"
  Write-Host "Usable after restart: $(Format-K $after)"
  if ($limits -and $limits.Max -and $Value -gt $limits.Max) {
    Write-Host "Note: Codex caps $Model at $(Format-K $limits.Max), so the window stops there; the rest is reserved by Codex."
  }
  Write-Host 'Next: quit Codex completely, reopen it and start a NEW conversation.'
} finally {
  if ($locked) { Remove-Item -LiteralPath $lockPath }
}
