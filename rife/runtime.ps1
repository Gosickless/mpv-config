param(
 [ValidateSet('Install','Uninstall','Launch','Probe','Prepare','Plan','CleanLogs')][string]$Action='Probe',
 [string]$Root=(Join-Path $env:LOCALAPPDATA 'mpv-rife'),
 [string]$ConfigDir=(Split-Path $PSScriptRoot -Parent),
 [string]$Mpv='', [string]$CancelFile='', [string]$Request='',
 [string]$PauseFile='', [string]$ProgressFile='', [switch]$Confirmed
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Read-Json($Path){ Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Write-Json($Path,$Value){
 $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 8))
 for($attempt=0;$attempt -lt 20;$attempt++){
  try{
   if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
   return
  }catch{if($attempt -eq 19){throw};Start-Sleep -Milliseconds 20}
 }
}
function File-Sha256($Path){
 $stream=[IO.File]::OpenRead($Path);$hash=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
 finally{$stream.Dispose();$hash.Dispose()}
}
function Publish($Value){
 if(-not $ProgressFile){$script:ProgressFile=Join-Path $Root 'progress.json'}
 Write-Json $ProgressFile $Value
}
function Cancel-Check { if($CancelFile -and (Test-Path -LiteralPath $CancelFile)){throw 'Cancelled'} }
function Open-PrepareLogLease {
 for($attempt=0;$attempt -lt 50;$attempt++){
  Cancel-Check
  try{return [IO.File]::Open((Join-Path $Root 'install.lock'),'OpenOrCreate','Read','Read')}
  catch [IO.IOException]{if($attempt -eq 49){throw};Start-Sleep -Milliseconds 100}
 }
}
function Clear-PrepareLogs {
 if(-not [IO.Directory]::Exists($Root)){return}
 if((Get-Item -LiteralPath $Root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){return}
 $lockPath=Join-Path $Root 'install.lock'
 if((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){return}
 try{$lease=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')}
 catch [IO.IOException]{return} # Another player is still preparing, or installation is busy.
 try{
  foreach($item in (Get-ChildItem -LiteralPath $Root -File -Force)){
   if($item.Name -notmatch '^prepare-[0-9a-f]{32}\.jsonl(\.stderr)?$' -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
   try{Remove-Item -LiteralPath $item.FullName -ErrorAction Stop}
   catch [IO.IOException]{} # Also tolerate files held by an older preparation process.
   catch [UnauthorizedAccessException]{}
  }
 }finally{$lease.Dispose()}
}
function Clear-Staging($Path){
 $prefix=[IO.Path]::GetFullPath((Join-Path $Root 'staging')).TrimEnd('\')+'\'
 $resolved=[IO.Path]::GetFullPath($Path)
 if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notmatch '^[0-9a-f]{32}$'){throw 'Invalid staging cleanup path'}
 if(-not (Test-Path -LiteralPath $resolved)){return}
 $items=@(Get-Item -LiteralPath $resolved)+@(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
 foreach($item in $items){
  if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($item.FullName -ne $resolved -and -not [IO.Path]::GetFullPath($item.FullName).StartsWith($resolved+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'Unsafe staging entry'}
 }
 foreach($item in ($items | Sort-Object {$_.FullName.Length} -Descending)){Remove-Item -LiteralPath $item.FullName -Force}
}
function Expand-SafeZip($Archive,$Destination){
 [IO.Directory]::CreateDirectory($Destination)|Out-Null
 $prefix=[IO.Path]::GetFullPath($Destination).TrimEnd('\')+'\'
 $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
 try { foreach($entry in $zip.Entries){
  Cancel-Check
  $target=[IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
  if(-not $target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Archive path escape'}
  if(-not $entry.Name){[IO.Directory]::CreateDirectory($target)|Out-Null;continue}
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null
  [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$true)
 }} finally {$zip.Dispose()}
}
function Expand-Safe7z($Archive,$Destination){
 $names=@(& tar.exe -tf $Archive);if($LASTEXITCODE -ne 0){throw "Cannot list $Archive"}
 foreach($name in $names){if([IO.Path]::IsPathRooted($name) -or $name -match '(^|[/\\])\.\.([/\\]|$)' -or $name.Contains(':')){throw 'Archive path escape'}}
 $listing=@(& tar.exe -tvf $Archive);if($LASTEXITCODE -ne 0){throw 'Cannot inspect archive'}
 if($listing | Where-Object {$_ -match '^[lh]'} ){throw 'Archive links are not supported'}
 [IO.Directory]::CreateDirectory($Destination)|Out-Null
 & tar.exe -xf $Archive -C $Destination
 if($LASTEXITCODE -ne 0){throw "Cannot extract $Archive"}
 Cancel-Check
}
function Download-Checked($Asset,$Directory){
 $dest=Join-Path $Directory $Asset.name
 $part=$dest+'.part'
 $completed=if($null -ne $script:CompletedBytes){$script:CompletedBytes}else{0L}
 $all=if($null -ne $script:DownloadTotal){$script:DownloadTotal}else{$Asset.size}
 if(Test-Path -LiteralPath $dest){
  Publish @{phase='verifying';file=$Asset.name;overall=$completed;total=$all}
  if((File-Sha256 $dest) -eq $Asset.sha256){return $dest}
 }
 while($true){
  Cancel-Check
  while($PauseFile -and (Test-Path -LiteralPath $PauseFile)){
   $offset=if(Test-Path -LiteralPath $part){(Get-Item -LiteralPath $part).Length}else{0L}
   Publish @{phase='paused';file=$Asset.name;bytes=$offset;overall=($completed+$offset);total=$all}
   Start-Sleep -Milliseconds 200;Cancel-Check
  }
  $offset=if(Test-Path -LiteralPath $part){(Get-Item -LiteralPath $part).Length}else{0L}
  if($offset -ge $Asset.size){
   Publish @{phase='verifying';file=$Asset.name;overall=($completed+[math]::Min($offset,$Asset.size));total=$all}
   if($offset -eq $Asset.size -and (File-Sha256 $part) -eq $Asset.sha256){break}
   # Reset only our own invalid partial download.
   [IO.File]::Create($part).Dispose();$offset=0L
  }
  Publish @{phase='download';file=$Asset.name;bytes=$offset;overall=($completed+$offset);total=$all}
  $request=[Net.HttpWebRequest]::Create($Asset.url)
  $request.UserAgent='mpv-rife-installer';$request.Timeout=30000;$request.ReadWriteTimeout=30000
  if($offset -gt 0){$request.AddRange($offset)}
  $response=$null;$inputStream=$null;$output=$null;$paused=$false
  try{
   $response=$request.GetResponse()
   if([int]$response.StatusCode -eq 206){
    $range=$response.Headers['Content-Range']
    if($range -notmatch ('^bytes '+$offset+'-[0-9]+/'+$Asset.size+'$')){throw 'Invalid HTTP resume range'}
   }else{
    # A server may ignore Range: restart, never append a full response.
    $offset=0L
   }
   $inputStream=$response.GetResponseStream()
   $mode=if($offset -gt 0){[IO.FileMode]::Append}else{[IO.FileMode]::Create}
   $output=[IO.File]::Open($part,$mode,[IO.FileAccess]::Write,[IO.FileShare]::Read)
   $buffer=New-Object byte[] 262144;$bytes=$offset;$last=0L
   $watch=[Diagnostics.Stopwatch]::StartNew()
   while($true){
    Cancel-Check
    if($PauseFile -and (Test-Path -LiteralPath $PauseFile)){$paused=$true;break}
    $n=$inputStream.Read($buffer,0,$buffer.Length);if($n -eq 0){break}
    $output.Write($buffer,0,$n);$bytes+=$n
    if($bytes -gt $Asset.size){throw 'Download exceeds expected size'}
    if($watch.ElapsedMilliseconds-$last -ge 250){
     $output.Flush();$last=$watch.ElapsedMilliseconds
     Publish @{phase='download';file=$Asset.name;bytes=$bytes;overall=($completed+$bytes);total=$all}
    }
   }
  }finally{
   if($output){$output.Dispose()};if($inputStream){$inputStream.Dispose()};if($response){$response.Dispose()}
  }
  if($paused){continue}
  if((Get-Item -LiteralPath $part).Length -ne $Asset.size){throw 'Download interrupted; retry to resume'}
  Publish @{phase='verifying';file=$Asset.name;overall=($completed+$Asset.size);total=$all}
  if((File-Sha256 $part) -ne $Asset.sha256){
   [IO.File]::Create($part).Dispose();throw 'Download SHA256 mismatch; retry required'
  }
  break
 }
 if([IO.File]::Exists($dest)){[IO.File]::Replace($part,$dest,[NullString]::Value)}else{[IO.File]::Move($part,$dest)}
 return $dest
}

try{
 $Root=[IO.Path]::GetFullPath($Root)
 if($Action -eq 'CleanLogs'){Clear-PrepareLogs;exit 0}
 if($Action -eq 'Uninstall'){
  if(-not $Confirmed){throw 'Uninstall requires confirmation in the component manager'}
  . (Join-Path $PSScriptRoot 'maintenance.ps1')
  Remove-RifeComponents $Root $ConfigDir
  Write-Output 'Uninstalled'
  exit 0
 }
 if($Action -eq 'Plan'){
  $manifest=Read-Json (Join-Path $PSScriptRoot 'runtime-lock.json')
  @{root=$Root;id=$manifest.id;bytes=($manifest.assets|Measure-Object size -Sum).Sum;experimental=$true;assets=$manifest.assets} | ConvertTo-Json -Depth 6
  exit 0
 }
 if($Action -eq 'Install'){
  $lock=Read-Json (Join-Path $PSScriptRoot 'runtime-lock.json')
  if(-not $Confirmed){
   & (Join-Path $PSScriptRoot 'manager.ps1') -Root $Root -ConfigDir $ConfigDir -Mpv $Mpv
   exit $LASTEXITCODE
  }
  [IO.Directory]::CreateDirectory($Root)|Out-Null
  $mutex=[IO.File]::Open((Join-Path $Root 'install.lock'),'OpenOrCreate','ReadWrite','None')
  $stage=$null
  try{
   $drive=New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Root));if($drive.AvailableFreeSpace -lt 12GB){throw 'Insufficient disk space: need 12 GiB'}
   $downloads=Join-Path $Root 'downloads'
   [IO.Directory]::CreateDirectory($downloads)|Out-Null
   $script:DownloadTotal=($lock.assets|Measure-Object size -Sum).Sum
   $script:CompletedBytes=0L
   foreach($asset in $lock.assets){Download-Checked $asset $downloads|Out-Null;$script:CompletedBytes+=$asset.size}
   $stage=Join-Path $Root ('staging/'+[guid]::NewGuid().ToString('N'))
   [IO.Directory]::CreateDirectory($stage)|Out-Null
   Publish @{phase='extracting'}
   $runtime=Join-Path $stage 'runtime'
   Expand-SafeZip (Join-Path $downloads 'python.zip') $runtime
   Expand-SafeZip (Join-Path $downloads 'vs.whl') (Join-Path $runtime 'Lib/site-packages')
   [IO.File]::WriteAllText((Join-Path $runtime 'python313._pth'),"python313.zip`n.`nLib/site-packages`nimport site`n")
   # Adjacent marker prevents VS discovering globally installed plugins.
   [IO.File]::WriteAllText((Join-Path $runtime 'Lib/site-packages/vapoursynth/portable.vs'),'')
   $joined=Join-Path $stage 'trt.7z';$out=[IO.File]::Create($joined)
   try{foreach($name in @('trt.7z.001','trt.7z.002')){$s=[IO.File]::OpenRead((Join-Path $downloads $name));try{$s.CopyTo($out)}finally{$s.Dispose()}}}finally{$out.Dispose()}
   Expand-Safe7z $joined (Join-Path $runtime 'plugins')
   Expand-Safe7z (Join-Path $downloads 'scripts.7z') (Join-Path $runtime 'scripts')
   $plugin=Get-ChildItem (Join-Path $runtime 'plugins') -Recurse -Filter 'vstrt.dll' | Select-Object -First 1
   if(-not $plugin){throw 'TensorRT plugin missing'}
   $modelDestination=Join-Path $plugin.DirectoryName 'models'
   [IO.Directory]::CreateDirectory($modelDestination)|Out-Null
   foreach($variant in @('','_lite','_heavy')){
    Expand-Safe7z (Join-Path $downloads ('rife_v4.25'+$variant+'.7z')) $modelDestination
    if(-not (Test-Path -LiteralPath (Join-Path $modelDestination ('rife_v2/rife_v4.25'+$variant+'.onnx')))){throw ('RIFE v4.25'+$variant+' model missing')}
   }
   $vs=Get-ChildItem $runtime -Recurse -Filter 'vsscript.dll' | Select-Object -First 1
   $script=Get-ChildItem (Join-Path $runtime 'scripts') -Recurse -Filter 'vsmlrt.py' | Select-Object -First 1
   if(-not $vs -or -not $script){throw 'Runtime files missing'}
   $layout=@{id=$lock.id;python='python.exe';vsscript=$vs.FullName.Substring($runtime.Length+1);plugin=$plugin.FullName.Substring($runtime.Length+1);scripts=$script.DirectoryName.Substring($runtime.Length+1);model=425;experimental=$true}
   Write-Json (Join-Path $runtime 'runtime.json') $layout
   @'
import os, sys
from pathlib import Path
runtime, plugin, scripts = map(Path, sys.argv[1:])
handles = [os.add_dll_directory(str(p)) for p in sorted({p.parent for p in runtime.rglob('*.dll')})]
sys.path.insert(0, str(scripts))
import vapoursynth as vs
vs.core.std.LoadPlugin(path=str(plugin))
import vsmlrt
print(vs.__version__, vsmlrt.__version__)
'@ | & (Join-Path $runtime 'python.exe') - $runtime $plugin.FullName $script.DirectoryName
   if($LASTEXITCODE -ne 0){throw 'VapourSynth/TensorRT compatibility check failed'}
   Cancel-Check
   $destination=Join-Path $Root ('runtime/'+$lock.id+'-'+[guid]::NewGuid().ToString('N'))
   [IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null
   if(-not [IO.Path]::GetFullPath($runtime).StartsWith([IO.Path]::GetFullPath($stage).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFullPath($destination).StartsWith([IO.Path]::GetFullPath((Join-Path $Root 'runtime')).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid runtime publication path'}
   Move-Item -LiteralPath $runtime -Destination $destination
   Clear-Staging $stage
   Write-Json (Join-Path $Root 'active.json') @{root=$destination;id=$lock.id;installed=$true;installed_at=[DateTime]::UtcNow.ToString('o');gpu_verified=$false;hdr_verified=$false}
   Publish @{phase='installed'}
   Write-Output 'Installed'
  }finally{try{if($stage){Clear-Staging $stage}}finally{$mutex.Dispose()}}
 }else{
  $active=Read-Json (Join-Path $Root 'active.json');$runtime=$active.root
  $prefix=[IO.Path]::GetFullPath((Join-Path $Root 'runtime')).TrimEnd('\')+'\'
  if(-not [IO.Path]::GetFullPath($runtime).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid runtime location'}
  $layout=Read-Json (Join-Path $runtime 'runtime.json')
  $env:VSSCRIPT_PATH=Join-Path $runtime $layout.vsscript
  $dirs=@($runtime,(Split-Path $env:VSSCRIPT_PATH -Parent))
  $dirs+=@(Get-ChildItem $runtime -Recurse -Filter '*.dll' | ForEach-Object DirectoryName | Select-Object -Unique)
  $env:PATH=($dirs -join ';')+';'+$env:PATH
  $env:MPV_RIFE_ROOT=$Root
  $env:PYTHONHOME=$runtime
  $env:PYTHONPATH=Join-Path $runtime 'Lib/site-packages'
  if($Action -eq 'Probe'){
   & (Join-Path $runtime 'python.exe') (Join-Path $PSScriptRoot 'probe.py') --root $Root
   exit $LASTEXITCODE
  }
  if($Action -eq 'Prepare'){
   if(-not $Request -or -not (Test-Path -LiteralPath $Request)){throw 'Missing request JSON'}
   $logLease=Open-PrepareLogLease
   try{
   $output=Join-Path $Root ('prepare-'+[guid]::NewGuid().ToString('N')+'.jsonl')
   $stderr=$output+'.stderr'
   $arguments=@(('"'+(Join-Path $PSScriptRoot 'prepare.py')+'"'),'--root',('"'+$Root+'"'),'--request',('"'+$Request+'"'))
   $child=Start-Process -FilePath (Join-Path $runtime 'python.exe') -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $output -RedirectStandardError $stderr
   $null=$child.Handle
   try{
    while(-not $child.HasExited){
     if($CancelFile -and (Test-Path -LiteralPath $CancelFile)){
      & taskkill.exe /PID $child.Id /T /F | Out-Null
      throw 'Cancelled'
     }
     Start-Sleep -Milliseconds 200;$child.Refresh()
    }
    $child.WaitForExit()
    Get-Content -LiteralPath $output
    if($child.ExitCode -ne 0){throw ('Engine preparation failed; log: '+$stderr)}
   }finally{$child.Dispose()}
   }finally{$logLease.Dispose()}
   exit 0
  }
  if(-not $Mpv -or -not (Test-Path -LiteralPath $Mpv)){throw 'Specify -Mpv with full path to mpv.exe'}
  # Arguments are quoted individually; no shell-built command or global environment edits.
  $args=@(('"--config-dir='+$ConfigDir.TrimEnd('\')+'"'),'--idle=yes','--force-window=yes')
  Start-Process -FilePath $Mpv -ArgumentList $args
  exit 0
 }
}catch{
 Write-Error $_ -ErrorAction Continue
 if($Action -ne 'Uninstall' -and (Test-Path -LiteralPath $Root)){
  $phase=if($_.Exception.Message -eq 'Cancelled'){'cancelled'}else{'error'}
  Publish @{phase=$phase;message=$_.Exception.Message}
 }
 exit 1
}
