# ============================================================================
#  Elaborado por SYSDOP LLC
# ----------------------------------------------------------------------------
#  Sync-IIS.ps1  -  Replica de configuracion IIS (HA) en MALLA entre 2 o MAS
#  servidores (topologia Activo-Activo-Activo). Los peers se definen en
#  C:\Supervisor\cluster.config (los pregunta Instalar.bat): NO hay IPs
#  hardcodeadas.
#
#  ESTRATEGIA (approach B - replica del applicationHost.config; SIN CommitChanges):
#    - Cuando editas IIS en un servidor (sitio/puerto/binding/app pool), IIS Manager
#      reescribe SU applicationHost.config (commit LOCAL e INTERACTIVO, que SI funciona).
#    - Este motor solo COPIA ese archivo a los OTROS servidores (por SMB). El IIS de
#      cada uno detecta el cambio del archivo y RECARGA solo. Nadie hace CommitChanges
#      por script -> NO ocurre el error 0x80070520 (que daba el modelo anterior con
#      app pools de cuenta de servicio).
#    - MALLA: cada nodo empuja su config a CADA peer con nombre por-origen
#      (applicationHost.<MIEQUIPO>.config) para que 2 pushers no se pisen. El Applier
#      revisa todos los entrantes y aplica el MAS RECIENTE (por fecha), si es mas nuevo
#      que el local. Asi el ultimo cambio hecho en cualquiera de los 3 gana en los 3.
#    - Inmediato: watcher sobre applicationHost.config (capta tambien la escritura
#      atomica de IIS) + backstop de seguridad.
#    - SEGURIDAD: antes de reemplazar, hace BACKUP del applicationHost.config local
#      en C:\Supervisor\state\apphost-bak\ (reversible). Valida con
#      'appcmd list config' tras aplicar; si quedara invalido, restaura el backup.
#
#  ROLES (2 tareas, ver Instalar.bat):
#    - Pusher  (usuario local): copia MI applicationHost.config a cada peer por SMB.
#    - Applier (SYSTEM): aplica el entrante mas reciente a mi config local.
#
#  REQUISITO DE CIFRADO: los app pools con cuenta de servicio guardan su password
#  cifrada con las llaves de IIS de la maquina. Si los servidores NO comparten esas
#  llaves (clonados con re-generacion de llaves), un app pool podria no arrancar en el
#  nodo receptor. Verificar en la prueba; si pasa, se sincronizan las llaves UNA vez
#  (ver IIS-HA-Enfoques.md). Si fueron clonados tal cual, ya las comparten.
# ============================================================================
param(
  [ValidateSet('Pusher','Applier','Both')][string]$Role = 'Both'
)
$ErrorActionPreference = 'Stop'

# ----------------------------- CONFIG ---------------------------------------
# Los PEERS (los OTROS servidores) los pregunta Instalar.bat y quedan en
# cluster.config como Peers=hostA,hostB. Sin IPs hardcodeadas: el mismo motor
# sirve para cualquier conjunto de servidores. Compatible con el viejo Peer=host.
$ClusterCfg  = 'C:\Supervisor\cluster.config'
$Mode        = 'DryRun'              # 'DryRun' (no reemplaza el config, solo log) | 'Live' (replica real)
$Base        = 'C:\Supervisor'
$LogFile     = "$Base\logs\iis_sync.log"
$StateDir    = "$Base\state"
$BakDir      = "$Base\state\apphost-bak"
$LocalIncoming = "$Base\incoming"
$CfgDir      = "$env:windir\System32\inetsrv\config"
$AppHostCfg  = "$CfgDir\applicationHost.config"
$DebounceMs  = 1500
$BackstopSec = 20
$Appcmd      = "$env:windir\System32\inetsrv\appcmd.exe"
$MyCfgName   = "applicationHost.$($env:COMPUTERNAME).config"   # nombre por-origen (evita que 2 pushers se pisen)
# ----------------------------------------------------------------------------

# Lee los PEERS del cluster.config (los escribe Instalar.bat). Error claro si falta.
$Peers = @()
if (Test-Path -LiteralPath $ClusterCfg) {
  foreach ($ln in (Get-Content -LiteralPath $ClusterCfg)) {
    if ($ln -match '^\s*Peers\s*=\s*(.+)$') {
      $Peers = @($Matches[1] -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } elseif ($ln -match '^\s*Peer\s*=\s*(\S+)') {
      if ($Peers.Count -eq 0) { $Peers = @($Matches[1].Trim()) }
    }
  }
}
$Peers = @($Peers | Where-Object { $_ -and ($_ -ine $env:COMPUTERNAME) } | Select-Object -Unique)
if ($Peers.Count -eq 0) {
  throw "No se encontro 'Peers=' (ni 'Peer=') en $ClusterCfg. Corre Instalar.bat (te preguntara los OTROS servidores de la malla)."
}
$LocalIP  = $env:COMPUTERNAME   # solo para el log (identifica este nodo)
$PeersTxt = ($Peers -join ', ')

foreach ($d in @((Split-Path $LogFile), $StateDir, $BakDir, $LocalIncoming)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$script:lastPushedTicks = 0

function Log([string]$m){
  $line = "[{0}] [{1}->mesh] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $LocalIP, $m
  for ($i = 0; $i -lt 4; $i++) { try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 75 } }
}

function Cfg-Ticks { try { (Get-Item -LiteralPath $AppHostCfg -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { 0 } }

# --- PUSHER: copia MI applicationHost.config al incoming de CADA peer (preserva fecha) ---
# Se copia DIRECTO al nombre por-origen (applicationHost.<MIEQUIPO>.config): asi dos
# pushers distintos nunca escriben el mismo archivo (sin ventana de carrera) y el
# receptor elige el mas reciente entre todos. Reintenta si el config esta bloqueado.
function Push-ConfigToPeers([string]$reason){
  try {
    $srcItem = Get-Item -LiteralPath $AppHostCfg -ErrorAction SilentlyContinue
    if (-not $srcItem) { Log "WARN applicationHost.config local no accesible ($reason)"; return }
    $ticks = $srcItem.LastWriteTimeUtc.Ticks
    if ($ticks -eq $script:lastPushedTicks -and $reason -ne 'startup') { return }   # nada cambio
    $pushedAny = $false
    foreach ($peer in $Peers) {
      $peerIncoming = "\\$peer\C$\Supervisor\incoming"
      if (-not (Test-Path -LiteralPath $peerIncoming)) {
        try { New-Item -ItemType Directory -Path $peerIncoming -Force | Out-Null }
        catch { Log "WARN peer incoming inaccesible ($peerIncoming) ($reason): $($_.Exception.Message)"; continue }
      }
      $dstNamed = Join-Path $peerIncoming $MyCfgName
      $done = $false
      for ($try = 0; $try -lt 3 -and -not $done; $try++) {
        try {
          Copy-Item -LiteralPath $AppHostCfg -Destination $dstNamed -Force -ErrorAction Stop
          # preserva la fecha del config original (el receptor decide por fecha)
          (Get-Item -LiteralPath $dstNamed).LastWriteTimeUtc = $srcItem.LastWriteTimeUtc
          $done = $true
        } catch { Start-Sleep -Milliseconds 400 }   # config bloqueado un instante: reintenta
      }
      if (-not $done) { Log "ERROR push config a $peer ($reason): no se pudo copiar (bloqueado)"; continue }
      $pushedAny = $true
      Log "PUSH applicationHost.config -> $peer ($reason)"
    }
    if ($pushedAny) { $script:lastPushedTicks = $ticks }
  } catch { Log "ERROR Push-ConfigToPeers ($reason): $($_.Exception.Message)" }
}

# --- APPLIER (SYSTEM): aplica el applicationHost.config entrante MAS RECIENTE al IIS local ---
function Apply-IncomingConfig {
  try {
    # Reune todos los entrantes: por-origen (applicationHost.<host>.config) + legacy (applicationHost.config).
    $cands = @()
    $cands += @(Get-ChildItem -LiteralPath $LocalIncoming -Filter 'applicationHost.*.config' -File -ErrorAction SilentlyContinue)
    $legacy = Join-Path $LocalIncoming 'applicationHost.config'
    if (Test-Path -LiteralPath $legacy) { $cands += (Get-Item -LiteralPath $legacy) }
    if ($cands.Count -eq 0) { return }
    # el mas reciente por fecha gana
    $winner = $cands | Sort-Object { $_.LastWriteTimeUtc.Ticks } -Descending | Select-Object -First 1
    $incTicks = $winner.LastWriteTimeUtc.Ticks
    $locTicks = Cfg-Ticks
    if ($incTicks -le $locTicks) {                      # gana el mas reciente (el local)
      foreach ($c in $cands) { Remove-Item -LiteralPath $c.FullName -Force -ErrorAction SilentlyContinue }
      return
    }
    if ($Mode -ne 'Live') {                             # DryRun: no escribe el config local
      Log "DryRun: APLICARIA el applicationHost.config entrante de $($winner.Name) (mas reciente), pero no se escribe."
      foreach ($c in $cands) { Remove-Item -LiteralPath $c.FullName -Force -ErrorAction SilentlyContinue }
      return
    }
    # backup del config local antes de reemplazar (reversible)
    $bak = Join-Path $BakDir ("applicationHost.{0:yyyyMMdd-HHmmss}.config" -f (Get-Date))
    Copy-Item -LiteralPath $AppHostCfg -Destination $bak -Force -ErrorAction SilentlyContinue
    # aplica el ganador (preservando su fecha) sobre el config local
    Copy-Item -LiteralPath $winner.FullName -Destination $AppHostCfg -Force -ErrorAction Stop
    (Get-Item -LiteralPath $AppHostCfg).LastWriteTimeUtc = $winner.LastWriteTimeUtc
    # limpia todos los entrantes ya procesados
    foreach ($c in $cands) { Remove-Item -LiteralPath $c.FullName -Force -ErrorAction SilentlyContinue }
    # validar que IIS lee el config; si no, restaurar backup
    $null = & $Appcmd list config 2>$null
    if ($LASTEXITCODE -ne 0) {
      Log "ERROR el applicationHost.config aplicado NO valida (appcmd rc=$LASTEXITCODE) -> RESTAURANDO backup"
      Copy-Item -LiteralPath $bak -Destination $AppHostCfg -Force -ErrorAction SilentlyContinue
      return
    }
    Log "APLICADA applicationHost.config entrante de $($winner.Name) (IIS recarga solo). backup: $bak"
  } catch { Log "ERROR Apply-IncomingConfig: $($_.Exception.Message)" }
}

# --- Instancia unica (por rol) ---
try {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*Sync-IIS.ps1*' -and $_.CommandLine -like "*-Role $Role*" } |
    ForEach-Object { Log "Instancia previa $Role (PID $($_.ProcessId)) -> terminada"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }

$doPush  = ($Role -eq 'Pusher'  -or $Role -eq 'Both')
$doApply = ($Role -eq 'Applier' -or $Role -eq 'Both')
Log "==== Sync-IIS v3 MALLA (replica de config) iniciado ====  Role=$Role  Local=$LocalIP  peers=$($Peers.Count) [$PeersTxt]  como=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
if ($doApply) { Apply-IncomingConfig }
if ($doPush)  { Push-ConfigToPeers 'startup' }

$queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
if ($doPush) {
  $wCfg = New-Object System.IO.FileSystemWatcher (Split-Path $AppHostCfg), 'applicationHost.config'
  $wCfg.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size, CreationTime'
  $wCfg.EnableRaisingEvents = $true
  foreach ($ev in 'Changed','Created','Renamed') { Register-ObjectEvent $wCfg $ev -MessageData $queue -Action { $Event.MessageData.Enqueue('config') } | Out-Null }
}
if ($doApply) {
  $wIn = New-Object System.IO.FileSystemWatcher $LocalIncoming, 'applicationHost.*.config'
  $wIn.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size, CreationTime'
  $wIn.EnableRaisingEvents = $true
  foreach ($ev in 'Created','Changed','Renamed') { Register-ObjectEvent $wIn $ev -MessageData $queue -Action { $Event.MessageData.Enqueue('incoming') } | Out-Null }
}

$lastBackstop = Get-Date
while ($true) {
  Start-Sleep -Milliseconds 500
  if ($queue.Count -gt 0) {
    $kinds = @{}
    while ($queue.Count -gt 0) { $kinds[[string]$queue.Dequeue()] = $true }
    if ($doApply -and $kinds.ContainsKey('incoming')) { Start-Sleep -Milliseconds 400; Apply-IncomingConfig }
    if ($doPush  -and $kinds.ContainsKey('config'))   { Start-Sleep -Milliseconds $DebounceMs; Push-ConfigToPeers 'applicationHost-changed' }
  }
  if (((Get-Date) - $lastBackstop).TotalSeconds -ge $BackstopSec) {
    if ($doApply) { Apply-IncomingConfig }
    if ($doPush)  { Push-ConfigToPeers 'backstop' }
    $lastBackstop = Get-Date
  }
}
