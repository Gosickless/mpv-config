param([Parameter(Mandatory=$true)][string]$Mpv,[string]$Root=(Join-Path $env:LOCALAPPDATA 'mpv-rife'))
& "$PSScriptRoot/runtime.ps1" -Action Launch -Mpv $Mpv -Root $Root -ConfigDir (Split-Path $PSScriptRoot -Parent)
