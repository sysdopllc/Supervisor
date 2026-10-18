# ============================================================================
#  Elaborado por SYSDOP LLC
# ----------------------------------------------------------------------------
#  Sync-IIS.ps1  -  Replica de configuracion IIS (HA) entre 2 servidores.
#  El peer se define en C:\Supervisor\cluster.config (lo pregunta Instalar.bat):
#  NO hay IPs hardcodeadas.
#
#  ESTRATEGIA (approach B - replica del applicationHost.config; SIN CommitChanges):
#    - Cuando editas IIS en un servidor (sitio/puerto/binding/app pool), IIS Manager
#      reescribe SU applicationHost.config (commit LOCAL e INTERACTIVO, que SI funciona).
#    - Este motor solo COPIA ese archivo al otro servidor (por SMB). El IIS del otro
#      detecta el cambio del archivo y RECARGA solo. Nadie hace CommitChanges por
#      script -> NO ocurre el error 0x80070520 (que daba el modelo anterior con
#      app pools de cuenta de servicio).
#    - Inmediato: watcher sobre applicationHost.config (capta tambien la escritura
#      atomica de IIS) + backstop de seguridad.
#    - GANA EL MAS RECIENTE (robocopy /XO por fecha del archivo): bidireccional, y
#      al reiniciar un nodo NO pisa los cambios mas nuevos del otro (anti-perdida).
#    - SEGURIDAD: antes de reemplazar, hace BACKUP del applicationHost.config local
#      en C:\Supervisor\state\apphost-bak\ (reversible). Valida con
#      'appcmd list config' tras aplicar; si quedara invalido, restaura el backup.
#
#  ROLES (2 tareas, ver Instalar.bat):
#    - Pusher  (usuario local): copia MI applicationHost.config al peer por SMB.
#    - Applier (SYSTEM): aplica el entrante a mi config local (escribe en inetsrv).
#
#  REQUISITO DE CIFRADO: los app pools con cuenta de servicio guardan su password
#  cifrada con las llaves de IIS de la maquina. Si los 2 servidores NO comparten esas
#  llaves (clonados con re-generacion de llaves), un app pool podria no arrancar en el
#  nodo receptor. Verificar en la prueba; si pasa, se sincronizan las llaves UNA vez
#  (ver IIS-HA-Enfoques.md). Si fueron clonados tal cual, ya las comparten.
# ============================================================================
param(
  [ValidateSet('Pusher','Applier','Both')][string]$Role = 'Both'
)
$ErrorActionPreference = 'Stop'

# ----------------------------- CONFIG ---------------------------------------
# El PEER (el OTRO servidor) lo pregunta Instalar.bat y queda en cluster.config.
# Sin IPs hardcodeadas: el mismo motor sirve para cualquier par de servidores.
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
# ----------------------------------------------------------------------------

# Lee el PEER y el ROL del cluster.config (lo escribe Instalar.bat). Error claro si falta.
# OJO: el parametro -Role (Pusher/Applier/Both) es el rol de la TAREA; $ClusterRole
# (Active/Passive) es el rol del NODO en la topologia A>P. En A>P solo el ACTIVO
# empuja y solo el PASIVO aplica: asi la replica es unidireccional (no bidireccional).
$Peer = $null
$ClusterRole = $null
if (Test-Path -LiteralPath $ClusterCfg) {
  foreach ($ln in (Get-Content -LiteralPath $ClusterCfg)) {
    if ($ln -match '^\s*Peer\s*=\s*(\S+)') { $Peer = $Matches[1] }
    if ($ln -match '^\s*Role\s*=\s*(\S+)') { $ClusterRole = $Matches[1] }
  }
}
if ([string]::IsNullOrWhiteSpace($Peer)) {
  throw "No se encontro 'Peer=' en $ClusterCfg. Corre Instalar.bat (te preguntara la IP o nombre del OTRO servidor)."
}
if ([string]::IsNullOrWhiteSpace($ClusterRole)) { $ClusterRole = 'Active' }   # compat: sin Rol, asume Activo
$IsActive = ($ClusterRole -ieq 'Active')
$LocalIP = $env:COMPUTERNAME   # solo para el log (identifica este nodo)

$PeerIncoming = "\\$Peer\C$\Supervisor\incoming"
foreach ($d in @((Split-Path $LogFile), $StateDir, $BakDir, $LocalIncoming)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$script:lastPushedTicks = 0

function Log([string]$m){
  $line = "[{0}] [{1}->{2}] {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $LocalIP, $Peer, $m
  for ($i = 0; $i -lt 4; $i++) { try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 75 } }
}

function Cfg-Ticks { try { (Get-Item -LiteralPath $AppHostCfg -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { 0 } }

# --- PUSHER: copia MI applicationHost.config al incoming del peer (preserva fecha) ---
function Push-ConfigToPeer([string]$reason){
  try {
    $ticks = Cfg-Ticks
    if ($ticks -eq $script:lastPushedTicks -and $reason -ne 'startup') { return }   # nada cambio
    if (-not (Test-Path -LiteralPath $PeerIncoming)) {
      try { New-Item -ItemType Directory -Path $PeerIncoming -Force | Out-Null }
      catch { Log "WARN peer incoming inaccesible ($PeerIncoming) ($reason): $($_.Exception.Message)"; return }
    }
    # robocopy preserva el timestamp (/COPY:DAT) -> el receptor decide por fecha (/XO).
    $null = & robocopy $CfgDir $PeerIncoming 'applicationHost.config' '/COPY:DAT' '/R:2' '/W:2' '/NJH' '/NJS' '/NDL' '/NP' '/NFL'
    if ($LASTEXITCODE -ge 8) { Log "ERROR push config al peer ($reason) exit=$LASTEXITCODE"; return }
    $script:lastPushedTicks = $ticks
    Log "PUSH applicationHost.config -> $Peer ($reason)"
  } catch { Log "ERROR Push-ConfigToPeer ($reason): $($_.Exception.Message)" }
}

# --- APPLIER (SYSTEM): aplica el applicationHost.config entrante al IIS local ---
function Apply-IncomingConfig {
  $inc = Join-Path $LocalIncoming 'applicationHost.config'
  if (-not (Test-Path -LiteralPath $inc)) { return }
  try {
    $incTicks = (Get-Item -LiteralPath $inc).LastWriteTimeUtc.Ticks
    $locTicks = Cfg-Ticks
    if ($incTicks -le $locTicks) {                      # gana el mas reciente
      Log "Config entrante mas vieja/igual (gana la local) -> NO se aplica (anti-perdida)"
      Remove-Item -LiteralPath $inc -Force -ErrorAction SilentlyContinue; return
    }
    if ($Mode -ne 'Live') {                             # DryRun: no escribe el config local
      Log "DryRun: APLICARIA el applicationHost.config entrante del peer (mas reciente), pero no se escribe."
      Remove-Item -LiteralPath $inc -Force -ErrorAction SilentlyContinue; return
    }
    # backup del config local antes de reemplazar (reversible)
    $bak = Join-Path $BakDir ("applicationHost.{0:yyyyMMdd-HHmmss}.config" -f (Get-Date))
    Copy-Item -LiteralPath $AppHostCfg -Destination $bak -Force -ErrorAction SilentlyContinue
    # /XO = solo copia si el entrante es mas nuevo; preserva fecha
    $null = & robocopy $LocalIncoming $CfgDir 'applicationHost.config' '/XO' '/COPY:DAT' '/R:2' '/W:2' '/NJH' '/NJS' '/NDL' '/NP' '/NFL'
    $rc = $LASTEXITCODE
    Remove-Item -LiteralPath $inc -Force -ErrorAction SilentlyContinue
    if ($rc -ge 8) { Log "ERROR aplicar config entrante exit=$rc"; return }
    if (($rc -band 1) -eq 0) { return }                 # robocopy no copio (no era mas nuevo)
    # validar que IIS lee el config; si no, restaurar backup
    $null = & $Appcmd list config 2>$null
    if ($LASTEXITCODE -ne 0) {
      Log "ERROR el applicationHost.config aplicado NO valida (appcmd rc=$LASTEXITCODE) -> RESTAURANDO backup"
      Copy-Item -LiteralPath $bak -Destination $AppHostCfg -Force -ErrorAction SilentlyContinue
      return
    }
    Log "APLICADA applicationHost.config entrante (IIS recarga solo). backup: $bak"
  } catch { Log "ERROR Apply-IncomingConfig: $($_.Exception.Message)" }
}

# --- Instancia unica (por rol) ---
try {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*Sync-IIS.ps1*' -and $_.CommandLine -like "*-Role $Role*" } |
    ForEach-Object { Log "Instancia previa $Role (PID $($_.ProcessId)) -> terminada"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }

# A>P unidireccional: el ACTIVO solo empuja; el PASIVO solo aplica. La tarea Pusher
# en el pasivo y la tarea Applier en el activo quedan en reposo (idle), de modo que un
# Invertir-Roles.bat (que cambia Role= y reinicia) baste para invertir el sentido.
$doPush  = (($Role -eq 'Pusher'  -or $Role -eq 'Both') -and $IsActive)
$doApply = (($Role -eq 'Applier' -or $Role -eq 'Both') -and (-not $IsActive))
Log "==== Sync-IIS A>P (replica de config) iniciado ====  TaskRole=$Role  NodoRol=$ClusterRole  doPush=$doPush  doApply=$doApply  Local=$LocalIP  Peer=$Peer  como=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
if (-not $doPush -and -not $doApply) {
  Log "Esta tarea queda en reposo en este nodo (TaskRole=$Role no aplica al NodoRol=$ClusterRole en A>P). Latido cada ~5 min."
  while ($true) { Start-Sleep -Seconds 300; Log "idle (TaskRole=$Role / NodoRol=$ClusterRole)" }
}
if ($doApply) { Apply-IncomingConfig }
if ($doPush)  { Push-ConfigToPeer 'startup' }

$queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
if ($doPush) {
  $wCfg = New-Object System.IO.FileSystemWatcher (Split-Path $AppHostCfg), 'applicationHost.config'
  $wCfg.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size, CreationTime'
  $wCfg.EnableRaisingEvents = $true
  foreach ($ev in 'Changed','Created','Renamed') { Register-ObjectEvent $wCfg $ev -MessageData $queue -Action { $Event.MessageData.Enqueue('config') } | Out-Null }
}
if ($doApply) {
  $wIn = New-Object System.IO.FileSystemWatcher $LocalIncoming, 'applicationHost.config'
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
    if ($doPush  -and $kinds.ContainsKey('config'))   { Start-Sleep -Milliseconds $DebounceMs; Push-ConfigToPeer 'applicationHost-changed' }
  }
  if (((Get-Date) - $lastBackstop).TotalSeconds -ge $BackstopSec) {
    if ($doApply) { Apply-IncomingConfig }
    if ($doPush)  { Push-ConfigToPeer 'backstop' }
    $lastBackstop = Get-Date
  }
}
