param(
 [ValidateSet('Install','Launch','Probe','Prepare','Plan')][string]$Action='Probe',
 [string]$Root=(Join-Path $env:LOCALAPPDATA 'mpv-rife'),
 [string]$ConfigDir=(Split-Path $PSScriptRoot -Parent),
 [string]$Mpv='', [string]$CancelFile='', [string]$Request=''
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Read-Json($Path){ Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Write-Json($Path,$Value){ $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'; [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 8)); Move-Item -LiteralPath $temp -Destination $Path -Force }
function Cancel-Check { if($CancelFile -and (Test-Path -LiteralPath $CancelFile)){throw 'Cancelled'} }
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
 if(Test-Path -LiteralPath $dest){if((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Asset.sha256){return $dest}}
 $part=$dest+'.part'
 $request=[Net.HttpWebRequest]::Create($Asset.url);$request.UserAgent='mpv-rife-installer';$request.Timeout=30000;$request.ReadWriteTimeout=30000
 $response=$request.GetResponse();$inputStream=$response.GetResponseStream();$output=[IO.File]::Create($part)
 try{$buffer=New-Object byte[] 1048576;$bytes=0L
  while(($n=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){Cancel-Check;$output.Write($buffer,0,$n);$bytes+=$n
   Write-Json (Join-Path $Root 'progress.json') @{phase='download';file=$Asset.name;bytes=$bytes;total=$Asset.size}
  }
 }finally{$output.Dispose();$inputStream.Dispose();$response.Dispose()}
 if($Asset.size -gt 0 -and (Get-Item -LiteralPath $part).Length -ne $Asset.size){throw 'Download size mismatch'}
 if((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Asset.sha256){throw 'Download SHA256 mismatch'}
 Move-Item -LiteralPath $part -Destination $dest -Force
 return $dest
}
try{
 $Root=[IO.Path]::GetFullPath($Root)
 if($Action -eq 'Plan'){
  $manifest=Read-Json (Join-Path $PSScriptRoot 'runtime-lock.json')
  @{root=$Root;id=$manifest.id;bytes=($manifest.assets|Measure-Object size -Sum).Sum;experimental=$true;assets=$manifest.assets} | ConvertTo-Json -Depth 6
  exit 0
 }
 if($Action -eq 'Install'){
  $lock=Read-Json (Join-Path $PSScriptRoot 'runtime-lock.json')
  Add-Type -AssemblyName System.Windows.Forms
  $gb=[math]::Round(($lock.assets|Measure-Object size -Sum).Sum/1GB,2)
  $answer=[Windows.Forms.MessageBox]::Show("实验性 RIFE 扩展：下载约 $gb GiB，准备至少 12 GiB 可用空间。`n保存到：$Root`n需要支持 CUDA 13.2 的 NVIDIA 驱动。此依赖组合尚未在 RTX 5070 上验收。`n不会修改系统 Python 或 PATH。安装后需用配套启动器重启 mpv。`n是否开始下载？",'安装 AI 补帧环境','YesNo','Question')
  if($answer -ne 'Yes'){Write-Output 'Cancelled';exit 0}
  [IO.Directory]::CreateDirectory($Root)|Out-Null
  $mutex=[IO.File]::Open((Join-Path $Root 'install.lock'),'OpenOrCreate','ReadWrite','None')
  try{
   $drive=New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Root));if($drive.AvailableFreeSpace -lt 12GB){throw 'Insufficient disk space: need 12 GiB'}
   $stage=Join-Path $Root ('staging/'+[guid]::NewGuid().ToString('N'));$downloads=Join-Path $Root 'downloads'
   [IO.Directory]::CreateDirectory($stage)|Out-Null;[IO.Directory]::CreateDirectory($downloads)|Out-Null
   foreach($asset in $lock.assets){Download-Checked $asset $downloads|Out-Null}
   Write-Json (Join-Path $Root 'progress.json') @{phase='extracting'}
   $runtime=Join-Path $stage 'runtime'
   Expand-SafeZip (Join-Path $downloads 'python.zip') $runtime
   Expand-SafeZip (Join-Path $downloads 'vs.zip') (Join-Path $stage 'vs')
   $wheel=Get-ChildItem (Join-Path $stage 'vs/wheel') -Filter '*.whl' | Select-Object -First 1
   if(-not $wheel){throw 'VapourSynth wheel missing'}
   Expand-SafeZip $wheel.FullName (Join-Path $runtime 'Lib/site-packages')
   [IO.File]::WriteAllText((Join-Path $runtime 'python313._pth'),"python313.zip`n.`nLib/site-packages`nimport site`n")
   # Adjacent marker prevents VS discovering globally installed plugins.
   [IO.File]::WriteAllText((Join-Path $runtime 'Lib/site-packages/vapoursynth/portable.vs'),'')
   $joined=Join-Path $stage 'trt.7z';$out=[IO.File]::Create($joined)
   try{foreach($name in @('trt.7z.001','trt.7z.002')){$s=[IO.File]::OpenRead((Join-Path $downloads $name));try{$s.CopyTo($out)}finally{$s.Dispose()}}}finally{$out.Dispose()}
   Expand-Safe7z $joined (Join-Path $runtime 'plugins')
   Expand-Safe7z (Join-Path $downloads 'scripts.7z') (Join-Path $runtime 'scripts')
   $plugin=Get-ChildItem (Join-Path $runtime 'plugins') -Recurse -Filter 'vstrt.dll' | Select-Object -First 1
   if(-not $plugin){throw 'TensorRT plugin missing'}
   Expand-Safe7z (Join-Path $downloads 'models.7z') (Join-Path $stage 'models')
   $model=Get-ChildItem (Join-Path $stage 'models') -Recurse -Filter 'rife_v4.25.onnx' | Select-Object -First 1
   if(-not $model){throw 'RIFE v4.25 model missing'}
   $modelsRoot=Split-Path (Split-Path $model.FullName -Parent) -Parent
   $modelDestination=Join-Path $plugin.DirectoryName 'models'
   [IO.Directory]::CreateDirectory($modelDestination)|Out-Null
   Get-ChildItem -LiteralPath $modelsRoot -Force | Copy-Item -Destination $modelDestination -Recurse -Force
   $vs=Get-ChildItem $runtime -Recurse -Filter 'vsscript.dll' | Select-Object -First 1
   $script=Get-ChildItem (Join-Path $runtime 'scripts') -Recurse -Filter 'vsmlrt.py' | Select-Object -First 1
   if(-not $vs -or -not $script){throw 'Runtime files missing'}
   $layout=@{id=$lock.id;python='python.exe';vsscript=$vs.FullName.Substring($runtime.Length+1);plugin=$plugin.FullName.Substring($runtime.Length+1);scripts=$script.DirectoryName.Substring($runtime.Length+1);model=425;experimental=$true}
   Write-Json (Join-Path $runtime 'runtime.json') $layout
   & (Join-Path $runtime 'python.exe') -c 'import vapoursynth; print(vapoursynth.__version__)'
   if($LASTEXITCODE -ne 0){throw 'VapourSynth import failed'}
   $destination=Join-Path $Root ('runtime/'+$lock.id+'-'+[guid]::NewGuid().ToString('N'))
   [IO.Directory]::CreateDirectory((Split-Path $destination -Parent))|Out-Null
   Move-Item -LiteralPath $runtime -Destination $destination
   Write-Json (Join-Path $Root 'active.json') @{root=$destination;id=$lock.id;installed=$true;gpu_verified=$false;hdr_verified=$false}
   Write-Json (Join-Path $Root 'progress.json') @{phase='installed';message='Restart through launch.ps1; GPU/HDR not verified'}
   Write-Output 'Installed. Restart using rife/launch.ps1. GPU and HDR remain unverified.'
  }finally{$mutex.Dispose()}
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
   $output=Join-Path $Root ('prepare-'+[guid]::NewGuid().ToString('N')+'.jsonl')
   $stderr=$output+'.stderr'
   $arguments=@(('"'+(Join-Path $PSScriptRoot 'prepare.py')+'"'),'--root',('"'+$Root+'"'),'--request',('"'+$Request+'"'))
   $child=Start-Process -FilePath (Join-Path $runtime 'python.exe') -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $output -RedirectStandardError $stderr
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
   exit 0
  }
  if(-not $Mpv -or -not (Test-Path -LiteralPath $Mpv)){throw 'Specify -Mpv with full path to mpv.exe'}
  # Arguments are quoted individually; no shell-built command or global environment edits.
  $args=@(('"--config-dir='+$ConfigDir.TrimEnd('\')+'"'),'--idle=yes','--force-window=yes')
  Start-Process -FilePath $Mpv -ArgumentList $args
 }
}catch{
 Write-Error $_ -ErrorAction Continue
 if(Test-Path -LiteralPath $Root){Write-Json (Join-Path $Root 'progress.json') @{phase='error';message=$_.Exception.Message}}
 exit 1
}
