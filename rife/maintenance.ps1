# Shared uninstall preflight. Never recursively remove an arbitrary Root.
function Get-RifeRemovalItems($Root,$ConfigDir){
 $resolved=[IO.Path]::GetFullPath($Root).TrimEnd('\')
 $config=[IO.Path]::GetFullPath($ConfigDir).TrimEnd('\')
 if($resolved -eq [IO.Path]::GetPathRoot($resolved).TrimEnd('\') -or
    $resolved -eq [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\') -or
    $config.Equals($resolved,[StringComparison]::OrdinalIgnoreCase) -or
    $config.StartsWith($resolved+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe component root'}
 $ancestor=$resolved
 while($ancestor){
  if((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked component directory is not supported'}
  $parent=Split-Path $ancestor -Parent;if($parent -eq $ancestor){break};$ancestor=$parent
 }
 if(-not (Test-Path -LiteralPath $resolved)){return}
 $pending=New-Object 'Collections.Generic.Queue[string]'
 foreach($item in @(Get-ChildItem -LiteralPath $resolved -Force)){
  if($item.Name -eq 'install.lock'){continue}
  if($item.PSIsContainer){
   if($item.Name -notin @('runtime','cache','downloads','staging','jobs','logs')){throw ('Unknown directory in component root: '+$item.Name)}
  }elseif($item.Name -notin @('active.json','progress.json') -and $item.Name -notmatch '^(prepare-[0-9a-f]{32}\.jsonl(\.stderr)?|request-[0-9]+-[0-9]+\.json)$'){
   throw ('Unknown file in component root: '+$item.Name)
  }
  $pending.Enqueue($item.FullName)
 }
 while($pending.Count){
  $path=$pending.Dequeue();$item=Get-Item -LiteralPath $path -Force
  if(-not $item.FullName.StartsWith($resolved+'\',[StringComparison]::OrdinalIgnoreCase) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe component entry'}
  $item
  if($item.PSIsContainer){foreach($child in @(Get-ChildItem -LiteralPath $path -Force)){$pending.Enqueue($child.FullName)}}
 }
}
function Assert-RifeNotInUse($Root){
 $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
 foreach($process in @(Get-Process -Name 'mpv','python','pythonw','vspipe' -ErrorAction SilentlyContinue)){
  try{
   if(-not $process.Modules -and -not $process.HasExited){throw 'Cannot inspect process modules'}
   foreach($module in $process.Modules){
    if($module.FileName.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'RIFE_IN_USE'}
   }
  }catch{
   # An inaccessible player cannot safely be assumed to have no loaded runtime.
   throw 'RIFE_IN_USE: Close players and component preparation processes before uninstalling'
  }
 }
}
function Remove-RifeComponents($Root,$ConfigDir){
 # Validate *all* entries before removing anything; reject junctions and user files.
 $items=@(Get-RifeRemovalItems $Root $ConfigDir)
 if(-not (Test-Path -LiteralPath $Root)){return}
 $mutex=[IO.File]::Open((Join-Path $Root 'install.lock'),'OpenOrCreate','ReadWrite','None')
 try{
  Assert-RifeNotInUse $Root
  $items=@(Get-RifeRemovalItems $Root $ConfigDir)
  foreach($item in $items){
   if(-not $item.PSIsContainer){
    $probe=[IO.File]::Open($item.FullName,'Open','ReadWrite','None');$probe.Dispose()
   }
  }
  foreach($item in ($items | Sort-Object {$_.FullName.Length} -Descending)){Remove-Item -LiteralPath $item.FullName -Force}
 }finally{$mutex.Dispose()}
 Remove-Item -LiteralPath (Join-Path $Root 'install.lock') -Force
 # Nonrecursive: any unexpected file created meanwhile prevents root removal.
 [IO.Directory]::Delete([IO.Path]::GetFullPath($Root))
}
