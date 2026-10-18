# ============================================================================
#  Elaborado por SYSDOP LLC
# ----------------------------------------------------------------------------
#  Sync-WebConfig.ps1  -  Replica bidireccional REALTIME (event-driven)
#  entre 2 servidores. El peer se define en C:\Supervisor\cluster.config
#  (lo pregunta Instalar.bat): NO hay IPs hardcodeadas.
#
#  ESTRATEGIA (v3 - directory watch puro, sin escaneos abusivos):
#    - Un FileSystemWatcher RECURSIVO por carpeta. Cada cambio (nuevo,
#      modificado, renombrado, borrado) se propaga AL INSTANTE, solo esa
#      ruta. NO se recorre el arbol (no "find all" de millones de inodes).
#    - Gana la version mas reciente: robocopy /XO (compara fecha+size) y
#      conserva timestamp -> la direccion inversa lo omite (anti ping-pong).
#    - BORRADO recursivo: borrar una carpeta borra la carpeta completa en
#      el peer (Remove-Item -Recurse). Tombstone corto evita que el peer la
#      resucite mientras el borrado se asienta.
#    - RETRY: si robocopy falla porque el archivo esta BLOQUEADO (una app lo
#      tiene abierto), se reintenta hasta $MaxRetries veces con espera
#      creciente, hasta que el proceso lo libere.
#    - Sync inicial UNA sola vez al arrancar (robocopy nativo, rapido). Un
#      backstop opcional muy espaciado (robocopy /XO aditivo) recupera
#      cambios perdidos si el watcher tuvo overflow. Nada de Get-ChildItem.
#    - LOGS no se replican (cada server tiene los suyos; ademas estan
#      bloqueados): carpetas logs/Logs/Log y *.log/*.tmp/*.etl/log.sqlite/
#      *.sqlite-wal/*.sqlite-shm.
#    - Solo robocopy.exe (binario firmado de Windows). Nada que instalar.
# ============================================================================

$ErrorActionPreference = 'Stop'

# ----------------------------- CONFIG ---------------------------------------
# El PEER (el OTRO servidor del par) lo pregunta Instalar.bat y queda escrito en
# C:\Supervisor\cluster.config. Asi el MISMO motor sirve para CUALQUIER par de
# servidores sin editar el script (no hay IPs hardcodeadas).
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

# Lee el PEER del cluster.config (lo escribe Instalar.bat). Sin esto no se sabe
# con quien replicar -> error claro (no se asume nada).
$Peer = $null
if (Test-Path -LiteralPath $ClusterCfg) {
  foreach ($ln in (Get-Content -LiteralPath $ClusterCfg)) {
    if ($ln -match '^\s*Peer\s*=\s*(\S+)') { $Peer = $Matches[1] }
  }
}
if ([string]::IsNullOrWhiteSpace($Peer)) {
  throw "No se encontro 'Peer=' en $ClusterCfg. Corre Instalar.bat (te preguntara la IP o nombre del OTRO servidor)."
}
$LocalIP = $env:COMPUTERNAME   # solo para el log (identifica este nodo)

if (-not (Test-Path (Split-Path $LogFile))) { New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null }

# Omite AUTOMATICAMENTE las rutas de $AppPaths que NO existan en ESTE servidor.
# Asi una carpeta inexistente (otra unidad, otro layout) no genera ruido ni cicla:
# simplemente se descarta y el resto se replica normal. Se registra una vez al
# arrancar (lineas OMITIDA en el log). Si luego se crea esa carpeta, reinicia la
# tarea WebConfigSync para que la tome.
$OmittedPaths = @($AppPaths | Where-Object { -not (Test-Path -LiteralPath ($_.TrimEnd('\'))) })
$ActivePaths  = @($AppPaths | Where-Object {       (Test-Path -LiteralPath ($_.TrimEnd('\'))) })

$jobs = foreach ($ap in $ActivePaths) {
  $full        = $ap.TrimEnd('\')
  $qualifier   = Split-Path -Qualifier $full
  $driveLetter = $qualifier.TrimEnd(':')
  $rest        = $full.Substring($qualifier.Length).TrimStart('\')
  [pscustomobject]@{
    AppPath   = $full
    LocalDir  = $full
    RemoteDir = "\\$Peer\$driveLetter`$\$rest"
    ShareRoot = "\\$Peer\$driveLetter`$"
  }
}

function Log([string]$m){
  $line = "[{0}] [{1}->{2}] {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $LocalIP, $Peer, $m
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

$Tomb = @{}   # "key|rel" -> DateTime de expiracion del tombstone
function Add-Tomb($k,$rel){ $Tomb["$k|$rel"] = (Get-Date).AddSeconds($TombstoneSeconds) }
function Test-Tomb($k,$rel){
  $key = "$k|$rel"
  if ($Tomb.ContainsKey($key)) {
    if ((Get-Date) -lt $Tomb[$key]) { return $true }
    $Tomb.Remove($key)
  }
  return $false
}

# Propaga UN cambio. Devuelve: 'ok' | 'locked' | 'skip'
function Propagate-One($job, [string]$rel, [string]$type){
  if ([string]::IsNullOrEmpty($rel) -or (Test-Excluded $rel)) { return 'skip' }
  $peerPath  = Join-Path $job.RemoteDir $rel
  $localPath = Join-Path $job.LocalDir  $rel

  if ($type -eq 'Deleted') {
    Add-Tomb $job.AppPath $rel
    if (Test-Path -LiteralPath $peerPath) {
      try { Remove-Item -LiteralPath $peerPath -Recurse -Force -ErrorAction Stop; Log "DEL peer: $rel" }
      catch { Log "RETRY del ($rel): $($_.Exception.Message)"; return 'locked' }
    }
    return 'ok'
  }

  # Created / Changed / Renamed -> copia el archivo (o crea carpeta vacia)
  if (Test-Path -LiteralPath $localPath -PathType Container) {
    if (-not (Test-Path -LiteralPath $peerPath)) { New-Item -ItemType Directory -Path $peerPath -Force | Out-Null; Log "MKDIR peer: $rel" }
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
  Log "PUSH peer: $rel"
  return 'ok'
}

# ---- Sync inicial / backstop: robocopy NATIVO (sin recorrer con PowerShell) ----
function Robo-Both($job, [string]$reason){
  if (-not (Test-Path -LiteralPath $job.ShareRoot)) { Log "WARN peer no accesible: $($job.ShareRoot) ($reason)"; return }
  if (-not (Test-Path -LiteralPath $job.LocalDir))  { Log "WARN carpeta local no existe: $($job.LocalDir) ($reason)"; return }
  $null = & robocopy $job.LocalDir  $job.RemoteDir @RoboBulk; $p = $LASTEXITCODE
  $null = & robocopy $job.RemoteDir $job.LocalDir  @RoboBulk; $q = $LASTEXITCODE
  if (($p -band 1) -or ($q -band 1)) { Log "SYNC carpeta [$($job.AppPath)] push=$p pull=$q ($reason)" }
  if (($p -ge 8) -or ($q -ge 8))     { Log "WARN robocopy [$($job.AppPath)] push=$p pull=$q ($reason) - algunos archivos bloqueados, el watcher los reintenta" }
}

# --- Instancia unica ---
try {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*Sync-WebConfig.ps1*' } |
    ForEach-Object { Log "Instancia previa (PID $($_.ProcessId)) -> terminada"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }

Log "==== Sync v3 iniciado ====  carpetas activas=$($jobs.Count) de $($AppPaths.Count)  Local=$LocalIP  Peer=$Peer"
foreach ($op in $OmittedPaths) { Log "OMITIDA (no existe en este servidor, se ignora): $op" }
foreach ($job in $jobs) { Log "  carpeta: $($job.LocalDir)  <->  $($job.RemoteDir)" }
if ($jobs.Count -eq 0) { Log "AVISO: ninguna ruta de \$AppPaths existe en este servidor; nada que replicar. Revisa \$AppPaths o crea las carpetas y reinicia WebConfigSync." }
foreach ($job in $jobs) { Robo-Both $job 'startup' }   # convergencia inicial (una vez)

# --- Watchers: uno por carpeta, recursivos; encolan la RUTA exacta del cambio ---
$queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
$sb = {
  $e = $Event.SourceEventArgs
  $old = if ($e -is [System.IO.RenamedEventArgs]) { $e.OldFullPath } else { $null }
  $Event.MessageData.Queue.Enqueue([pscustomobject]@{ Key=$Event.MessageData.Key; Path=$e.FullPath; Old=$old; Type=[string]$e.ChangeType })
}
$watchers = @()
for ($i = 0; $i -lt $jobs.Count; $i++) {
  $job = $jobs[$i]
  if (-not (Test-Path -LiteralPath $job.LocalDir)) { Log "WARN carpeta local no existe; watcher omitido: $($job.LocalDir)"; continue }
  $fsw = New-Object System.IO.FileSystemWatcher $job.LocalDir
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

# pending: "key|rel" -> @{Job;Rel;Type;Attempts;NextTry}   (lista de trabajo + reintentos)
$pending = [ordered]@{}
$lastBackstop = Get-Date

while ($true) {
  Start-Sleep -Milliseconds 150

  # 1) drenar eventos del watcher al set de trabajo (ultimo evento por ruta gana)
  if ($queue.Count -gt 0) {
    Start-Sleep -Milliseconds $DebounceMs
    while ($queue.Count -gt 0) {
      $it   = $queue.Dequeue()
      $job  = $jobs[$it.Key]
      $base = $job.LocalDir.TrimEnd('\') + '\'
      if ($it.Path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $it.Path.Substring($base.Length)
        if (-not (Test-Excluded $rel)) {
          $pending["$($it.Key)|$rel"] = @{ Job=$job; Rel=$rel; Type=$it.Type; Attempts=0; NextTry=(Get-Date) }
        }
      }
      # renombrado: el nombre viejo se trata como borrado
      if ($it.Old -and $it.Old.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        $relOld = $it.Old.Substring($base.Length)
        if (-not (Test-Excluded $relOld)) {
          $pending["$($it.Key)|$relOld"] = @{ Job=$job; Rel=$relOld; Type='Deleted'; Attempts=0; NextTry=(Get-Date) }
        }
      }
    }
  }

  # 2) procesar pendientes cuyo NextTry ya llego; reintentar los bloqueados
  if ($pending.Count -gt 0) {
    foreach ($k in @($pending.Keys)) {
      $p = $pending[$k]
      if ((Get-Date) -lt $p.NextTry) { continue }
      $r = Propagate-One $p.Job $p.Rel $p.Type
      if ($r -eq 'locked') {
        $p.Attempts++
        if ($p.Attempts -ge $MaxRetries) {
          Log "ERROR ($($p.Rel)) sigue bloqueado tras $MaxRetries intentos - se reintenta en el proximo cambio/backstop"
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
    # tras el backstop, re-aplica borrados recientes (tombstones) por si el peer los re-agrego
    foreach ($tk in @($Tomb.Keys)) {
      if ((Get-Date) -ge $Tomb[$tk]) { $Tomb.Remove($tk); continue }
      $parts = $tk -split '\|', 2
      $tjob  = $jobs | Where-Object { $_.AppPath -eq $parts[0] } | Select-Object -First 1
      if ($tjob) {
        foreach ($d in @((Join-Path $tjob.RemoteDir $parts[1]), (Join-Path $tjob.LocalDir $parts[1]))) {
          if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue; Log "DEL (tombstone): $($parts[1])" }
        }
      }
    }
    $lastBackstop = Get-Date
  }
}
