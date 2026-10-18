# ============================================================================
#  Elaborado por SYSDOP LLC
# ----------------------------------------------------------------------------
#  Sync-WebConfig.ps1  -  Replica bidireccional REALTIME en MALLA (event-driven)
#  entre 2 o MAS servidores (topologia Activo-Activo-Activo). Los peers se
#  definen en C:\Supervisor\cluster.config (los pregunta Instalar.bat):
#  NO hay IPs hardcodeadas.
#
#  MALLA ACTIVO-ACTIVO-ACTIVO:
#    - CADA nodo es ACTIVO. Todo cambio local se empuja a TODOS los peers
#      (los otros 2 servidores) al instante. Cada peer, a su vez, empuja lo
#      suyo a los demas. Asi los 3 (o N) convergen entre si.
#    - Gana la version MAS RECIENTE por archivo: robocopy /XO (compara
#      fecha+size) y conserva timestamp -> la direccion inversa lo omite
#      (anti ping-pong). No hay "maestro": cualquiera puede recibir el cambio.
#    - Convergencia inicial ADITIVA (/XO, NO /MIR): al arrancar copia lo que
#      falta o es mas nuevo en AMBOS sentidos hacia cada peer, SIN borrar nada.
#      Resultado: la UNION de los datos de los 3 nodos queda en los 3 (ideal
#      cuando cada servidor tiene datos/multimedia que a los otros les faltan).
#
#  ESTRATEGIA (v3 - directory watch puro, sin escaneos abusivos):
#    - Un FileSystemWatcher RECURSIVO por carpeta. Cada cambio (nuevo,
#      modificado, renombrado, borrado) se propaga AL INSTANTE, solo esa
#      ruta, a CADA peer. NO se recorre el arbol (no "find all" de millones
#      de inodes).
#    - BORRADO recursivo: borrar una carpeta la borra completa en cada peer
#      (Remove-Item -Recurse). Tombstone corto evita que un peer la resucite
#      mientras el borrado se asienta.
#    - RETRY por peer: si robocopy falla porque el archivo esta BLOQUEADO (una
#      app lo tiene abierto), reintenta hasta $MaxRetries veces con espera
#      creciente, hasta que el proceso lo libere. El retry es INDEPENDIENTE
#      por peer (que uno este bloqueado no frena a los demas).
#    - Sync inicial UNA sola vez al arrancar (robocopy nativo, rapido) contra
#      cada peer. Un backstop opcional muy espaciado (robocopy /XO aditivo)
#      recupera cambios perdidos si el watcher tuvo overflow. Nada de
#      Get-ChildItem.
#    - LOGS no se replican (cada server tiene los suyos; ademas estan
#      bloqueados): carpetas logs/Logs/Log y *.log/*.tmp/*.etl/log.sqlite/
#      *.sqlite-wal/*.sqlite-shm.
#    - Solo robocopy.exe (binario firmado de Windows). Nada que instalar.
# ============================================================================

$ErrorActionPreference = 'Stop'

# ----------------------------- CONFIG ---------------------------------------
# Los PEERS (los OTROS servidores de la malla) los pregunta Instalar.bat y
# quedan escritos en C:\Supervisor\cluster.config como  Peers=hostA,hostB.
# Asi el MISMO motor sirve para CUALQUIER conjunto de servidores sin editar el
# script (no hay IPs hardcodeadas). Compatible con el formato viejo Peer=host.
$ClusterCfg       = 'C:\Supervisor\cluster.config'

$AppPaths = @(
  'E:\ExampleApps'
  'E:\ExampleMedia'
  'C:\inetpub\wwwroot\example-site'
)

$LogFile          = 'C:\Supervisor\logs\webconfig_sync.log'
$DebounceMs       = 200           # espera tras un evento para agrupar rafagas del mismo archivo
$StableMs         = 150           # ventana entre 2 muestras para "archivo terminado de escribir"
$MaxRetries       = 5             # reintentos si el archivo esta bloqueado
$RetryDelaysSec   = @(3,8,15,30,45)   # espera antes de cada reintento (hasta liberar)
$BackstopMinutes  = 15            # red de seguridad robocopy /XO (0 = desactivar). NO recorre con PowerShell.
$TombstoneSeconds = 90            # ventana donde un borrado "gana" para que no lo resuciten

$ExcludeDirs  = @('logs','Logs','Log')
$ExcludeFiles = @('*.log','*.tmp','*.etl','log.sqlite','*.sqlite-wal','*.sqlite-shm')

# robocopy de UN archivo (instant). /R:2 /W:2 = micro-reintento del propio robocopy.
$RoboFile   = @('/COPY:DATSO','/B','/XO','/R:2','/W:2','/NJH','/NJS','/NDL','/NP','/NFL')
# robocopy de carpeta (solo startup + backstop). /MT rapido, /XO aditivo, excluye logs.
$RoboBulk   = @('/E','/XO','/COPY:DATSO','/DCOPY:DAT','/B','/R:2','/W:2','/XJ','/MT:16',
                '/NJH','/NJS','/NDL','/NP','/NFL',
                '/XD') + $ExcludeDirs + @('/XF') + $ExcludeFiles
# ----------------------------------------------------------------------------

# Lee los PEERS del cluster.config (los escribe Instalar.bat). Acepta:
#   Peers=hostA,hostB   (malla, formato nuevo)  |  Peer=host  (par, formato viejo)
# Sin esto no se sabe con quien replicar -> error claro (no se asume nada).
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
# Descarta este mismo servidor de la lista y deduplica (por si el instalador lo incluyo).
$Peers = @($Peers | Where-Object { $_ -and ($_ -ine $env:COMPUTERNAME) } | Select-Object -Unique)
if ($Peers.Count -eq 0) {
  throw "No se encontro 'Peers=' (ni 'Peer=') en $ClusterCfg. Corre Instalar.bat (te preguntara los OTROS servidores de la malla)."
}
$LocalIP  = $env:COMPUTERNAME   # solo para el log (identifica este nodo)
$PeersTxt = ($Peers -join ', ')

if (-not (Test-Path (Split-Path $LogFile))) { New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null }

# Omite AUTOMATICAMENTE las rutas de $AppPaths que NO existan en ESTE servidor.
# Asi una carpeta inexistente (otra unidad, otro layout) no genera ruido ni cicla:
# simplemente se descarta y el resto se replica normal. Se registra una vez al
# arrancar (lineas OMITIDA en el log). Si luego se crea esa carpeta, reinicia la
# tarea WebConfigSync para que la tome.
$OmittedPaths = @($AppPaths | Where-Object { -not (Test-Path -LiteralPath ($_.TrimEnd('\'))) })
$ActivePaths  = @($AppPaths | Where-Object {       (Test-Path -LiteralPath ($_.TrimEnd('\'))) })

# $paths = rutas locales activas (1 watcher por ruta).
# $jobs  = un trabajo por (ruta x peer): a donde empujar esa ruta en cada peer.
$paths = @()
for ($pi = 0; $pi -lt $ActivePaths.Count; $pi++) {
  $paths += ,([pscustomobject]@{ Index=$pi; LocalDir=$ActivePaths[$pi].TrimEnd('\') })
}
$jobs = foreach ($p in $paths) {
  $full        = $p.LocalDir
  $qualifier   = Split-Path -Qualifier $full
  $driveLetter = $qualifier.TrimEnd(':')
  $rest        = $full.Substring($qualifier.Length).TrimStart('\')
  foreach ($peer in $Peers) {
    [pscustomobject]@{
      PathIdx   = $p.Index
      Peer      = $peer
      AppPath   = $full
      LocalDir  = $full
      RemoteDir = "\\$peer\$driveLetter`$\$rest"
      ShareRoot = "\\$peer\$driveLetter`$"
    }
  }
}

function Log([string]$m){
  $line = "[{0}] [{1}->mesh] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $LocalIP, $m
  Add-Content -LiteralPath $LogFile -Value $line
}

function Test-Excluded([string]$rel){
  if ([string]::IsNullOrEmpty($rel)) { return $false }
  foreach ($seg in ($rel -split '[\\/]')) {
    foreach ($xd in $ExcludeDirs) { if ($seg -ieq $xd) { return $true } }
  }
  $leaf = Split-Path -Leaf $rel
  foreach ($xf in $ExcludeFiles) { if ($leaf -like $xf) { return $true } }
  return $false
}

# El archivo termino de escribirse? Estable en 2 muestras. Si esta bloqueado o
# cambiando, devuelve $false y se reintenta luego (no copia a medias).
function Test-FileReady([string]$path){
  try {
    $a = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    Start-Sleep -Milliseconds $StableMs
    $b = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    return ($a.Length -eq $b.Length -and $a.LastWriteTimeUtc.Ticks -eq $b.LastWriteTimeUtc.Ticks)
  } catch { return $false }
}

$Tomb = @{}   # "AppPath|rel" -> DateTime de expiracion del tombstone (por RUTA, aplica a todos los peers)
function Add-Tomb($k,$rel){ $Tomb["$k|$rel"] = (Get-Date).AddSeconds($TombstoneSeconds) }
function Test-Tomb($k,$rel){
  $key = "$k|$rel"
  if ($Tomb.ContainsKey($key)) {
    if ((Get-Date) -lt $Tomb[$key]) { return $true }
    $Tomb.Remove($key)
  }
  return $false
}

# Propaga UN cambio a UN peer (el job ya lleva su RemoteDir). Devuelve: 'ok' | 'locked' | 'skip'
function Propagate-One($job, [string]$rel, [string]$type){
  if ([string]::IsNullOrEmpty($rel) -or (Test-Excluded $rel)) { return 'skip' }
  $peerPath  = Join-Path $job.RemoteDir $rel
  $localPath = Join-Path $job.LocalDir  $rel

  if ($type -eq 'Deleted') {
    Add-Tomb $job.AppPath $rel
    if (Test-Path -LiteralPath $peerPath) {
      try { Remove-Item -LiteralPath $peerPath -Recurse -Force -ErrorAction Stop; Log "DEL $($job.Peer): $rel" }
      catch { Log "RETRY del $($job.Peer) ($rel): $($_.Exception.Message)"; return 'locked' }
    }
    return 'ok'
  }

  # Created / Changed / Renamed -> copia el archivo (o crea carpeta vacia)
  if (Test-Path -LiteralPath $localPath -PathType Container) {
    if (-not (Test-Path -LiteralPath $peerPath)) { New-Item -ItemType Directory -Path $peerPath -Force | Out-Null; Log "MKDIR $($job.Peer): $rel" }
    return 'ok'
  }
  if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) { return 'skip' }   # desaparecio
  if (-not (Test-FileReady $localPath)) { return 'locked' }                         # a medio escribir/bloqueado -> reintenta

  $srcDir = Split-Path -Parent $localPath
  $dstDir = Split-Path -Parent $peerPath
  $name   = Split-Path -Leaf  $localPath
  $null = & robocopy $srcDir $dstDir $name @RoboFile
  if ($LASTEXITCODE -ge 8) { return 'locked' }   # bloqueado -> reintenta
  if (Test-Tomb $job.AppPath $rel) { $Tomb.Remove("$($job.AppPath)|$rel") }   # re-creado: limpia tombstone
  Log "PUSH $($job.Peer): $rel"
  return 'ok'
}

# ---- Sync inicial / backstop: robocopy NATIVO (sin recorrer con PowerShell) ----
# Aditivo /XO en AMBOS sentidos por peer -> converge la UNION sin borrar.
function Robo-Both($job, [string]$reason){
  if (-not (Test-Path -LiteralPath $job.ShareRoot)) { Log "WARN peer no accesible: $($job.ShareRoot) ($reason)"; return }
  if (-not (Test-Path -LiteralPath $job.LocalDir))  { Log "WARN carpeta local no existe: $($job.LocalDir) ($reason)"; return }
  $null = & robocopy $job.LocalDir  $job.RemoteDir @RoboBulk; $p = $LASTEXITCODE
  $null = & robocopy $job.RemoteDir $job.LocalDir  @RoboBulk; $q = $LASTEXITCODE
  if (($p -band 1) -or ($q -band 1)) { Log "SYNC carpeta [$($job.AppPath)] $($job.Peer) push=$p pull=$q ($reason)" }
  if (($p -ge 8) -or ($q -ge 8))     { Log "WARN robocopy [$($job.AppPath)] $($job.Peer) push=$p pull=$q ($reason) - algunos archivos bloqueados, el watcher los reintenta" }
}

# --- Instancia unica ---
try {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*Sync-WebConfig.ps1*' } |
    ForEach-Object { Log "Instancia previa (PID $($_.ProcessId)) -> terminada"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }

Log "==== Sync v3 MALLA iniciado ====  carpetas activas=$($paths.Count) de $($AppPaths.Count)  peers=$($Peers.Count) [$PeersTxt]  Local=$LocalIP"
foreach ($op in $OmittedPaths) { Log "OMITIDA (no existe en este servidor, se ignora): $op" }
foreach ($p in $paths) { Log "  carpeta: $($p.LocalDir)  <->  [$PeersTxt]" }
if ($paths.Count -eq 0) { Log "AVISO: ninguna ruta de \$AppPaths existe en este servidor; nada que replicar. Revisa \$AppPaths o crea las carpetas y reinicia WebConfigSync." }
foreach ($job in $jobs) { Robo-Both $job 'startup' }   # convergencia inicial aditiva (una vez) contra cada peer

# --- Watchers: uno por carpeta, recursivos; encolan la RUTA exacta del cambio ---
$queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$sb = {
  $e = $Event.SourceEventArgs
  $old = if ($e -is [System.IO.RenamedEventArgs]) { $e.OldFullPath } else { $null }
  $Event.MessageData.Queue.Enqueue([pscustomobject]@{ Key=$Event.MessageData.Key; Path=$e.FullPath; Old=$old; Type=[string]$e.ChangeType })
}
$watchers = @()
for ($i = 0; $i -lt $paths.Count; $i++) {
  $localDir = $paths[$i].LocalDir
  if (-not (Test-Path -LiteralPath $localDir)) { Log "WARN carpeta local no existe; watcher omitido: $localDir"; continue }
  $fsw = New-Object System.IO.FileSystemWatcher $localDir
  $fsw.NotifyFilter = [System.IO.NotifyFilters]'LastWrite, Size, FileName, DirectoryName, CreationTime'
  $fsw.IncludeSubdirectories = $true
  $fsw.InternalBufferSize = 65536    # buffer grande: evita perder eventos en rafagas
  $fsw.EnableRaisingEvents = $true
  $md = [pscustomobject]@{ Queue=$queue; Key=$i }
  Register-ObjectEvent $fsw Changed -MessageData $md -Action $sb | Out-Null
  Register-ObjectEvent $fsw Created -MessageData $md -Action $sb | Out-Null
  Register-ObjectEvent $fsw Renamed -MessageData $md -Action $sb | Out-Null
  Register-ObjectEvent $fsw Deleted -MessageData $md -Action $sb | Out-Null
  $watchers += $fsw
}

# jobs indexados por PathIdx para expandir un evento de ruta a un trabajo por peer.
$jobsByPath = @{}
foreach ($job in $jobs) {
  if (-not $jobsByPath.ContainsKey($job.PathIdx)) { $jobsByPath[$job.PathIdx] = @() }
  $jobsByPath[$job.PathIdx] += $job
}

# pending: "pathIdx|peer|rel" -> @{Job;Rel;Type;Attempts;NextTry}  (trabajo + reintentos, INDEPENDIENTE por peer)
$pending = [ordered]@{}
$lastBackstop = Get-Date

# Encola un cambio de ruta hacia TODOS los peers (un pending por peer).
function Queue-AllPeers([int]$pathIdx, [string]$rel, [string]$type){
  if (Test-Excluded $rel) { return }
  foreach ($job in $jobsByPath[$pathIdx]) {
    $pending["$pathIdx|$($job.Peer)|$rel"] = @{ Job=$job; Rel=$rel; Type=$type; Attempts=0; NextTry=(Get-Date) }
  }
}

while ($true) {
  Start-Sleep -Milliseconds 150

  # 1) drenar eventos del watcher al set de trabajo (ultimo evento por ruta gana), expandiendo a cada peer
  if ($queue.Count -gt 0) {
    Start-Sleep -Milliseconds $DebounceMs
    while ($queue.Count -gt 0) {
      $it   = $queue.Dequeue()
      $base = $paths[$it.Key].LocalDir.TrimEnd('\') + '\'
      if ($it.Path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $it.Path.Substring($base.Length)
        Queue-AllPeers $it.Key $rel $it.Type
      }
      # renombrado: el nombre viejo se trata como borrado
      if ($it.Old -and $it.Old.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        $relOld = $it.Old.Substring($base.Length)
        Queue-AllPeers $it.Key $relOld 'Deleted'
      }
    }
  }

  # 2) procesar pendientes cuyo NextTry ya llego; reintentar los bloqueados (por peer)
  if ($pending.Count -gt 0) {
    foreach ($k in @($pending.Keys)) {
      $p = $pending[$k]
      if ((Get-Date) -lt $p.NextTry) { continue }
      $r = Propagate-One $p.Job $p.Rel $p.Type
      if ($r -eq 'locked') {
        $p.Attempts++
        if ($p.Attempts -ge $MaxRetries) {
          Log "ERROR ($($p.Job.Peer): $($p.Rel)) sigue bloqueado tras $MaxRetries intentos - se reintenta en el proximo cambio/backstop"
          $pending.Remove($k)
        } else {
          $delay = $RetryDelaysSec[[Math]::Min($p.Attempts-1, $RetryDelaysSec.Count-1)]
          $p.NextTry = (Get-Date).AddSeconds($delay)   # espera a que el proceso libere el archivo
        }
      } else {
        $pending.Remove($k)   # 'ok' o 'skip'
      }
    }
  }

  # 3) backstop ligero (robocopy nativo aditivo) - red de seguridad, no recorre con PowerShell
  if ($BackstopMinutes -gt 0 -and ((Get-Date) - $lastBackstop).TotalMinutes -ge $BackstopMinutes) {
    foreach ($job in $jobs) { Robo-Both $job 'backstop' }
    # tras el backstop, re-aplica borrados recientes (tombstones) por si algun peer los re-agrego
    foreach ($tk in @($Tomb.Keys)) {
      if ((Get-Date) -ge $Tomb[$tk]) { $Tomb.Remove($tk); continue }
      $parts = $tk -split '\|', 2
      $tjobs = $jobs | Where-Object { $_.AppPath -eq $parts[0] }
      foreach ($tjob in $tjobs) {
        foreach ($d in @((Join-Path $tjob.RemoteDir $parts[1]), (Join-Path $tjob.LocalDir $parts[1]))) {
          if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue; Log "DEL (tombstone) $($tjob.Peer): $($parts[1])" }
        }
      }
    }
    $lastBackstop = Get-Date
  }
}
