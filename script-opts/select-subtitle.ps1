param([string]$InitialDirectory)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
try {
    $dialog.Title = '选择本地字幕'
    $dialog.Filter = '字幕文件|*.ass;*.ssa;*.srt;*.vtt;*.sub;*.idx;*.sup;*.mks;*.smi;*.lrc;*.scc;*.rt;*.txt|所有文件|*.*'
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory -PathType Container)) {
        $dialog.InitialDirectory = (Resolve-Path -LiteralPath $InitialDirectory).Path
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        [Console]::Write($dialog.FileName)
    }
} finally {
    $dialog.Dispose()
}
