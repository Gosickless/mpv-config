param(
 [string]$Root=(Join-Path $env:LOCALAPPDATA 'mpv-rife'),
 [string]$ConfigDir=(Split-Path $PSScriptRoot -Parent),
 [string]$Mpv='',
 [string]$PreviewPath='',
 [ValidateSet('auto','initial','download','paused','installed','update','uninstalled','error')][string]$PreviewState='auto'
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$Root=[IO.Path]::GetFullPath($Root)
$manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime-lock.json') -Raw -Encoding UTF8|ConvertFrom-Json
$total=[double](($manifest.assets|Measure-Object size -Sum).Sum)
$sha=[Security.Cryptography.SHA256]::Create()
$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant())))).Replace('-','');$sha.Dispose()
$created=$false;$mutex=New-Object Threading.Mutex($true,('Local\mpv-rife-manager-'+$key),[ref]$created)
if(-not $created -and -not $PreviewPath){
 [Windows.Forms.MessageBox]::Show('安装管理窗口已打开，请切换到已有窗口。','AI 补帧','OK','Information')|Out-Null
 $mutex.Dispose();exit 0
}
$form=New-Object Windows.Forms.Form
$form.Text='AI 补帧 · 组件管理';$form.ClientSize=New-Object Drawing.Size(680,500)
$form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
$form.BackColor=[Drawing.Color]::FromArgb(250,248,250)
$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
$form.AutoScaleMode='Dpi'
function Label($Text,$X,$Y,$W,$H){
 $c=New-Object Windows.Forms.Label;$c.Text=$Text;$c.SetBounds($X,$Y,$W,$H);$c.ForeColor=[Drawing.Color]::FromArgb(52,43,55);$form.Controls.Add($c);return $c
}
$title=Label '安装 AI 补帧组件' 30 25 620 42
$title.Font=New-Object Drawing.Font('Microsoft YaHei UI',20,[Drawing.FontStyle]::Bold)
$subtitle=Label '安装完成后，可在播放器中开启更流畅的画面。' 32 78 615 49
$summary=Label ('需要下载约 {0:N2} GiB · 请预留至少 12 GiB 空间' -f ($total/1GB)) 32 137 615 28
$locationLabel=Label '安装位置' 32 177 615 25
$pathBox=New-Object Windows.Forms.TextBox;$pathBox.SetBounds(32,205,615,30);$pathBox.ReadOnly=$true;$pathBox.Text=$Root
$pathBox.BackColor=[Drawing.Color]::White;$form.Controls.Add($pathBox)
$phaseLabel=Label '点击“开始安装”后才会下载。' 32 257 615 26
$bar=New-Object Windows.Forms.ProgressBar;$bar.SetBounds(32,292,615,16);$bar.Maximum=1000;$bar.Style='Continuous';$form.Controls.Add($bar)
$detail=Label '' 32 321 615 42
$detail.ForeColor=[Drawing.Color]::FromArgb(103,92,108)
$primary=New-Object Windows.Forms.Button;$primary.SetBounds(32,392,190,44);$primary.FlatStyle='Flat'
$primary.FlatAppearance.BorderSize=0;$primary.BackColor=[Drawing.Color]::FromArgb(246,166,193)
$primary.ForeColor=[Drawing.Color]::FromArgb(36,25,38);$primary.Text='开始安装';$form.Controls.Add($primary)
$pause=New-Object Windows.Forms.Button;$pause.SetBounds(236,392,135,44);$pause.Text='暂停下载';$pause.Visible=$false;$form.Controls.Add($pause)
$folder=New-Object Windows.Forms.Button;$folder.SetBounds(385,392,125,44);$folder.Text='打开文件夹';$folder.Visible=$false;$form.Controls.Add($folder)
$details=New-Object Windows.Forms.Button;$details.SetBounds(524,392,123,44);$details.Text='查看详情';$form.Controls.Add($details)
$uninstall=New-Object Windows.Forms.Button;$uninstall.SetBounds(236,392,135,44);$uninstall.Text='卸载补帧组件';$uninstall.Visible=$false;$form.Controls.Add($uninstall)
$foot=Label '仅安装补帧所需组件，不更改现有画质设置。' 32 455 615 26
$foot.Font=New-Object Drawing.Font('Microsoft YaHei UI',9);$foot.ForeColor=[Drawing.Color]::FromArgb(110,100,115)
$script:worker=$null;$script:jobDir='';$script:busy=$false;$script:paused=$false;$script:closing=$false
$script:lastPhase='initial';$script:lastError='';$script:installed=$false
$script:operation='install'
function Installed-Record {
 $file=Join-Path $Root 'active.json'
 if(Test-Path -LiteralPath $file){
  try{
   $record=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json
   $prefix=[IO.Path]::GetFullPath((Join-Path $Root 'runtime')).TrimEnd('\')+'\'
   if($record.installed -and [IO.Path]::GetFullPath($record.root).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath (Join-Path $record.root 'runtime.json'))){return $record}
  }catch{}
 }
 return $null
}
function Show-State($State,$Data){
 $script:lastPhase=$State
 $script:installed=$false
 $uninstall.Visible=(-not $script:busy) -and ($State -in @('installed','update') -or $null -ne (Installed-Record))
 $bar.Style='Continuous';$bar.Visible=$true;$primary.Enabled=-not $script:busy;$pause.Visible=$false;$folder.Visible=Test-Path -LiteralPath $Root
 switch($State){
  'initial'{
   $title.Text='安装 AI 补帧组件';$subtitle.Text='安装完成后，可在播放器中开启更流畅的画面。'
   $phaseLabel.Text='准备就绪';$detail.Text='点击“开始安装”后才会下载。支持暂停和继续下载。';$primary.Text='开始安装';$bar.Value=0
  }
  'download'{
   $title.Text='正在下载补帧组件';$subtitle.Text='下载期间可以暂停；下次打开时可以继续，不必从头下载。'
   $phaseLabel.Text='下载进度';$primary.Text='安装中';$pause.Visible=$true;$pause.Enabled=$true;$pause.Text='暂停下载'
   $percent=[math]::Min(1000,[math]::Max(0,[int](1000*[double]$Data.overall/[double]$Data.total)))
   $bar.Value=$percent;$detail.Text=('{0:N2} / {1:N2} GiB  ·  {2:N1}%' -f ([double]$Data.overall/1GB),([double]$Data.total/1GB),($percent/10))
  }
  'paused'{
   $title.Text='下载已暂停';$subtitle.Text='已下载的内容已保留，点击“继续下载”即可接着安装。'
   $phaseLabel.Text='下载已暂停';$primary.Text='安装中';$pause.Visible=$true;$pause.Enabled=$true;$pause.Text='继续下载'
   $bar.Value=[math]::Min(1000,[math]::Max(0,[int](1000*[double]$Data.overall/[double]$Data.total)))
   $detail.Text=('{0:N2} / {1:N2} GiB 已下载' -f ([double]$Data.overall/1GB),([double]$Data.total/1GB))
  }
  'verifying'{
   $title.Text='正在检查下载文件';$subtitle.Text='正在确认文件完整，完成后将继续安装。';$phaseLabel.Text='检查文件';$detail.Text='请稍候，此步骤无需操作。';$bar.Style='Marquee';$primary.Text='安装中'
  }
  'extracting'{
   $title.Text='正在安装补帧组件';$subtitle.Text='下载已完成，正在解压并配置组件。';$phaseLabel.Text='正在安装';$detail.Text='此步骤不能暂停，安装窗口可以保持打开。';$bar.Style='Marquee';$primary.Text='安装中'
  }
  'installed'{
   $script:installed=$true;$title.Text='AI 补帧组件已安装';$subtitle.Text='组件已准备好，可返回当前播放器开启 AI 补帧。'
   $bar.Visible=$false;$summary.Text='安装状态：已安装';$phaseLabel.Text='安装完成';$detail.Text='关闭此窗口，在当前播放器右键菜单中开启补帧即可。';$bar.Value=1000;$primary.Text='返回播放器'
   if($Data -and $Data.installed_at){try{$detail.Text+='  安装于 '+([datetime]$Data.installed_at).ToLocalTime().ToString('yyyy-MM-dd HH:mm')}catch{}}
  }
  'update'{
   $title.Text='补帧组件需要更新';$subtitle.Text='已安装的组件与当前播放器配置不匹配，更新后可继续使用 AI 补帧。'
   $summary.Text=('本次需检查并下载约 {0:N2} GiB · 请预留至少 12 GiB 空间' -f ($total/1GB))
   $phaseLabel.Text='等待更新';$detail.Text='点击“开始更新”后才会下载；可复用的下载文件会保留。';$primary.Text='开始更新';$bar.Value=0
  }
  'uninstalled'{
   $title.Text='补帧组件已卸载';$subtitle.Text='已移除补帧环境、模型、缓存和下载文件。播放器配置已保留。'
   $summary.Text=('重新安装需下载约 {0:N2} GiB · 请预留至少 12 GiB 空间' -f ($total/1GB))
   $bar.Visible=$false;$phaseLabel.Text='卸载完成';$detail.Text='需要使用 AI 补帧时，可在这里重新安装。';$primary.Text='重新安装'
  }
  'error'{
   $title.Text='安装未完成';$subtitle.Text='已下载的内容会保留，可以稍后重试。';$phaseLabel.Text='需要重试';$detail.Text='请检查网络连接和剩余空间。具体原因可在“查看详情”中查看。';$primary.Text='重试安装';$bar.Value=0
  }
  'cancelled'{
   $title.Text='安装已停止';$subtitle.Text='已下载的内容会保留，下次可以继续。';$phaseLabel.Text='安装未完成';$detail.Text='点击“继续安装”可接着下载。';$primary.Text='继续安装'
  }
 }
}
$timer=New-Object Windows.Forms.Timer;$timer.Interval=300
$timer.Add_Tick({
 if(-not $script:busy){return}
 $progress=Join-Path $script:jobDir 'progress.json'
 if(Test-Path -LiteralPath $progress){
  try{$data=Get-Content -LiteralPath $progress -Raw -Encoding UTF8|ConvertFrom-Json
   if($data.phase -in @('download','paused','verifying','extracting')){Show-State $data.phase $data}
   if($data.phase -eq 'error'){$script:lastError=$data.message}
  }catch{}
 }
 if($script:closing){$title.Text='正在停止安装';$subtitle.Text='已下载内容会保留，请等待当前步骤结束。';$primary.Enabled=$false;$pause.Enabled=$false}
 $script:worker.Refresh()
 if($script:worker.HasExited){
  $script:worker.WaitForExit();$code=$script:worker.ExitCode;$script:worker.Dispose();$script:worker=$null;$script:busy=$false
  $record=Installed-Record
  if($script:operation -eq 'uninstall'){
   if($code -eq 0){Show-State 'uninstalled' $null}else{
    if($record){if($record.id -eq $manifest.id){Show-State 'installed' $record}else{Show-State 'update' $record}}else{Show-State 'initial' $null}
    $script:lastError=Get-Content -LiteralPath (Join-Path $script:jobDir 'error.log') -Raw -ErrorAction SilentlyContinue
    $detail.Text='卸载未完成。请关闭使用补帧组件的播放器后重试；仍无法卸载时可查看详情。'
   }
   $folder.Enabled=$true;$timer.Stop();return
  }
  if($code -eq 0 -and $record -and $record.id -eq $manifest.id){Show-State 'installed' $record}
  elseif($script:closing -or (Test-Path -LiteralPath (Join-Path $script:jobDir 'cancel'))){Show-State 'cancelled' $null}
  else{Show-State 'error' $null}
  if($script:closing){$form.Close()}
 }
})
$primary.Add_Click({
 if($script:busy){return}
 if($script:installed){
  $form.Close()
  return
 }
 try{
  [IO.Directory]::CreateDirectory($Root)|Out-Null
  $script:jobDir=Join-Path $Root ('jobs/'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($script:jobDir)|Out-Null
  $script:paused=$false;$script:lastError='';$script:closing=$false
  $script:operation='install'
  $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+(Join-Path $PSScriptRoot 'runtime.ps1')+'"'),'-Action','Install','-Confirmed','-Root',('"'+$Root+'"'),'-CancelFile',('"'+(Join-Path $script:jobDir 'cancel')+'"'),'-PauseFile',('"'+(Join-Path $script:jobDir 'pause')+'"'),'-ProgressFile',('"'+(Join-Path $script:jobDir 'progress.json')+'"'))
  $script:worker=Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $script:jobDir 'output.log') -RedirectStandardError (Join-Path $script:jobDir 'error.log')
  $null=$script:worker.Handle
  $script:busy=$true;Show-State 'verifying' $null;$phaseLabel.Text='正在准备下载';$timer.Start()
 }catch{$script:lastError=$_.Exception.Message;Show-State 'error' $null}
})
$pause.Add_Click({
 if(-not $script:busy){return}
 $file=Join-Path $script:jobDir 'pause'
 if($script:paused){
  if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}
  $script:paused=$false;$pause.Text='正在继续…';$pause.Enabled=$false
 }else{
  [IO.File]::WriteAllText($file,'pause');$script:paused=$true;$pause.Text='正在暂停…';$pause.Enabled=$false
 }
})
$folder.Add_Click({if(Test-Path -LiteralPath $Root){Start-Process -FilePath explorer.exe -ArgumentList ('"'+$Root+'"')}})
$uninstall.Add_Click({
 if($script:busy){return}
 $answer=[Windows.Forms.MessageBox]::Show("卸载将移除补帧环境、模型、缓存和已下载的组件包。播放器配置会保留，需要时可重新安装。`r`n`r`n请先关闭使用补帧组件的播放器。是否继续卸载？",'卸载补帧组件','YesNo','Question')
 if($answer -ne 'Yes'){return}
 try{
  # Worker logs must live outside the directory it removes.
  $script:jobDir=Join-Path ([IO.Path]::GetTempPath()) ('mpv-rife-uninstall-'+[guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($script:jobDir)|Out-Null
  $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+(Join-Path $PSScriptRoot 'runtime.ps1')+'"'),'-Action','Uninstall','-Confirmed','-Root',('"'+$Root+'"'),'-ConfigDir',('"'+$ConfigDir+'"'))
  $script:worker=Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $script:jobDir 'output.log') -RedirectStandardError (Join-Path $script:jobDir 'error.log')
  $null=$script:worker.Handle
  $script:operation='uninstall';$script:busy=$true;$script:lastError=''
  $primary.Enabled=$false;$uninstall.Visible=$false;$folder.Enabled=$false
  $title.Text='正在卸载补帧组件';$subtitle.Text='正在清理补帧组件，请保持窗口打开。';$phaseLabel.Text='正在卸载';$detail.Text='播放器配置会保留。';$bar.Visible=$true;$bar.Style='Marquee';$timer.Start()
 }catch{
  $script:busy=$false;$script:lastError=$_.Exception.Message
  $record=Installed-Record
  if($record){if($record.id -eq $manifest.id){Show-State 'installed' $record}else{Show-State 'update' $record}}else{Show-State 'initial' $null}
  $detail.Text='卸载未完成。请关闭使用补帧组件的播放器后重试；仍无法卸载时可查看详情。'
  [Windows.Forms.MessageBox]::Show('暂时无法完成卸载。请关闭使用补帧组件的播放器后重试；若仍失败，请查看详情。','AI 补帧','OK','Warning')|Out-Null
 }
})
$details.Add_Click({
 $message='安装位置：'+$Root+"`r`n组件版本："+$manifest.id+"`r`n"
 if($script:lastError){$message+="`r`n错误详情："+$script:lastError}
 if($script:jobDir){$message+="`r`n安装日志："+$script:jobDir}
 [Windows.Forms.MessageBox]::Show($message,'AI 补帧 · 详情','OK','Information')|Out-Null
})
$form.Add_FormClosing({param($sender,$event)
 if($script:busy -and $script:operation -eq 'uninstall'){$event.Cancel=$true;return}
 if($script:busy -and -not $script:closing){
  $answer=[Windows.Forms.MessageBox]::Show('安装尚未完成。关闭窗口会停止安装并保留已下载内容，下次可以继续。是否退出安装？','AI 补帧','YesNo','Question')
  $event.Cancel=$true
  if($answer -eq 'Yes'){
   [IO.File]::WriteAllText((Join-Path $script:jobDir 'cancel'),'cancel')
   $pauseFile=Join-Path $script:jobDir 'pause';if(Test-Path -LiteralPath $pauseFile){Remove-Item -LiteralPath $pauseFile}
   $script:closing=$true;$pause.Enabled=$false
  }
 }elseif($script:busy){$event.Cancel=$true}
})
$form.Add_Shown({$form.ActiveControl=$primary;$pathBox.SelectionLength=0})
$form.Add_FormClosed({$timer.Stop();$timer.Dispose()})
try{
 $record=Installed-Record
 if($record){if($record.id -eq $manifest.id){Show-State 'installed' $record}else{Show-State 'update' $record}}else{Show-State 'initial' $null}
 if($PreviewPath){
  $fake=@{overall=($total*.42);total=$total;installed_at='2026-11-06T08:00:00Z'}
  if($PreviewState -ne 'auto'){$script:busy=$PreviewState -in @('download','paused');Show-State $PreviewState $fake}
  $form.Show();$form.ActiveControl=$primary;$pathBox.SelectionLength=0;[Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 200;[Windows.Forms.Application]::DoEvents()
  $image=New-Object Drawing.Bitmap($form.Width,$form.Height)
  $rectangle=New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)
  $form.DrawToBitmap($image,$rectangle)
  $image.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png);$image.Dispose()
  @{title=$title.Text;primary=$primary.Text;pause=$pause.Text;pause_visible=$pause.Visible;installed=$script:installed;uninstall_visible=$uninstall.Visible} | ConvertTo-Json | Set-Content -LiteralPath ($PreviewPath+'.json') -Encoding UTF8
  $script:busy=$false;$form.Close()
 }else{[void]$form.ShowDialog()}
}finally{if($created){$mutex.ReleaseMutex()};$mutex.Dispose();$form.Dispose()}
