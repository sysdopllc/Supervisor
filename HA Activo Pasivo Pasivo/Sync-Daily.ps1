# ============================================================================
#  Elaborado por SYSDOP LLC
# ----------------------------------------------------------------------------
#  Sync-Daily.ps1  -  Rafaga DIARIA hacia el TERCER nodo (Pasivo2).
#  Topologia en cadena: Activo > Pasivo1 (tiempo real) > Pasivo2 (una vez al dia).
#  Este script se ejecuta UNA vez por disparo (tarea programada HASyncDaily,
#  por defecto 23:00) en el nodo que tiene Tertiary= en su cluster.config: el que
#  tiene ruta SMB (TCP 445) al 3er nodo, normalmente el Pasivo1. Empuja una copia
#  de las carpetas y del applicationHost.config al 3er nodo. NO corre en bucle.
#
#  Fuente de la rafaga: ESTE nodo. En el Pasivo1 sus datos son la replica en tiempo
#  real del Activo, asi que el Pasivo2 recibe lo mismo que tiene el Activo (salvo lo
#  que en ese instante siga en cola de replica).
#
#  Lee de C:\Supervisor\cluster.config:
#    Tertiary = IP o nombre del 3er nodo. Sin esto, no hace nada.
#    Role     = solo informativo para el log: la rafaga sale del nodo con Tertiary=,
#               sea Activo o Pasivo, asi un Invertir-Roles no la corta.
#  (TertiaryTime solo lo usa el instalador para fijar la hora de la tarea.)
#
#  Por defecto es ADITIVO (robocopy /XO: copia lo nuevo/mas reciente, NO borra
#  en el 3er nodo lo que ya no este en este nodo). Si quieres un espejo exacto
#  diario (que tambien elimine lo borrado), corre con -Mirror (usa /MIR; uselo
#  con cuidado: un glitch de este nodo podria borrar masivo en el 3er nodo).
# ============================================================================
param(
  [switch]$Mirror   # /MIR (espejo exacto, poda borrados). Default: aditivo /XO.
)
$ErrorActionPreference = 'Stop'

$ClusterCfg = 'C:\Supervisor\cluster.config'
$AppPaths = @(
  'E:\ExampleApps'
  'E:\ExampleMedia'
  'C:\inetpub\wwwroot\example-site'
)
$LogFile  = 'C:\Supervisor\logs\daily_sync.log'
$CfgDir   = "$env:windir\System32\inetsrv\config"
$AppHostCfg = "$CfgDir\applicationHost.config"

$ExcludeDirs  = @('logs','Logs','Log')
$ExcludeFiles = @('*.log','*.tmp','*.etl','log.sqlite','*.sqlite-wal','*.sqlite-shm')
$RoboMode = if ($Mirror) { '/MIR' } else { '/E','/XO' }
$RoboBulk = @($RoboMode) + @('/COPY:DATSO','/DCOPY:DAT','/B','/R:1','/W:1','/XJ','/MT:16',
              '/NJH','/NJS','/NDL','/NP','/NFL',
              '/XD') + $ExcludeDirs + @('/XF') + $ExcludeFiles

if (-not (Test-Path (Split-Path $LogFile))) { New-Item -ItemType Directory -Path (Split-Path $LogFile) -Force | Out-Null }

$Role = $null; $Tertiary = $null
if (Test-Path -LiteralPath $ClusterCfg) {
  foreach ($ln in (Get-Content -LiteralPath $ClusterCfg)) {
    if ($ln -match '^\s*Role\s*=\s*(\S+)')     { $Role = $Matches[1] }
    if ($ln -match '^\s*Tertiary\s*=\s*(\S+)') { $Tertiary = $Matches[1] }
  }
}
if ([string]::IsNullOrWhiteSpace($Role)) { $Role = 'Active' }
$LocalIP = $env:COMPUTERNAME

function Log([string]$m){
  $line = "[{0}] [{1}->{2}] {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $LocalIP, $Tertiary, $m
  Add-Content -LiteralPath $LogFile -Value $line
}

# La rafaga sale del nodo que tiene Tertiary=, sea Activo o Pasivo (el rol solo va al log).
if ([string]::IsNullOrWhiteSpace($Tertiary)) {
  Log "No hay Tertiary= en cluster.config (este nodo no envia rafaga diaria). Nada que enviar."
  return
}

Log "==== Rafaga diaria iniciada ====  Origen=$LocalIP (Rol=$Role)  ->  3er nodo=$Tertiary  modo=$(if($Mirror){'MIRROR /MIR'}else{'aditivo /XO'})"

# 1) Carpetas de datos
foreach ($ap in $AppPaths) {
  $full = $ap.TrimEnd('\')
  if (-not (Test-Path -LiteralPath $full)) { Log "OMITIDA (no existe aqui): $full"; continue }
  $qualifier   = Split-Path -Qualifier $full
  $driveLetter = $qualifier.TrimEnd(':')
  $rest        = $full.Substring($qualifier.Length).TrimStart('\')
  $remoteDir   = "\\$Tertiary\$driveLetter`$\$rest"
  $shareRoot   = "\\$Tertiary\$driveLetter`$"
  if (-not (Test-Path -LiteralPath $shareRoot)) { Log "WARN 3er nodo no accesible: $shareRoot (revisa SMB/firewall/credenciales)"; continue }
  $null = & robocopy $full $remoteDir @RoboBulk; $rc = $LASTEXITCODE
  if ($rc -ge 8) { Log "WARN robocopy [$full] rc=$rc (algunos archivos bloqueados; se reintenta en la proxima rafaga)" }
  else           { Log "OK carpeta [$full] -> $remoteDir (rc=$rc)" }
}

# 2) applicationHost.config -> incoming del 3er nodo (su Applier lo adopta)
try {
  $peerIncoming = "\\$Tertiary\C`$\Supervisor\incoming"
  if (-not (Test-Path -LiteralPath $peerIncoming)) { New-Item -ItemType Directory -Path $peerIncoming -Force | Out-Null }
  if (Test-Path -LiteralPath $AppHostCfg) {
    $null = & robocopy $CfgDir $peerIncoming 'applicationHost.config' '/COPY:DAT' '/R:2' '/W:2' '/NJH' '/NJS' '/NDL' '/NP' '/NFL'
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { Log "WARN push applicationHost.config rc=$rc" } else { Log "OK applicationHost.config -> $Tertiary (rc=$rc)" }
  }
} catch { Log "ERROR push applicationHost.config: $($_.Exception.Message)" }

Log "==== Rafaga diaria finalizada ===="
