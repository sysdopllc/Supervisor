# ============================================================================
#  Elaborado por SYSDOP LLC
# ----------------------------------------------------------------------------
#  Invertir-Roles.ps1  -  Cambia el SENTIDO de la replica A>P.
#  Intercambia Activo <-> Pasivo entre este nodo y su peer (failover/failback).
#
#  Que hace:
#    1. Lee C:\Supervisor\cluster.config (Peer y Role actuales).
#    2. Pone ESTE nodo en el rol OPUESTO y al PEER en el rol contrario,
#       escribiendo ambos cluster.config (el del peer por SMB: \\peer\C$\...).
#    3. Reinicia las tareas LOCALES (toman el rol nuevo al rearrancar).
#    4. Intenta reiniciar las tareas del PEER por schtasks /S (best-effort).
#       Si no puede (firewall/credenciales), te dice que corras en el peer:
#       Reiniciar-Tareas.bat  (reinicia sin volver a invertir).
#
#  CUIDADO (lo importante): tras invertir, el NUEVO ACTIVO se vuelve la fuente
#  de verdad y EMPUJA sobre el nuevo pasivo. Asegurate de promover el nodo que
#  tiene los datos BUENOS. Por eso pide confirmacion (usa -Force para omitirla).
#
#  Casos:
#    .\Invertir-Roles.ps1                 # swap normal (ambos nodos vivos)
#    .\Invertir-Roles.ps1 -Force          # sin confirmacion
#    .\Invertir-Roles.ps1 -PromoteLocalOnly  # el peer esta CAIDO: solo promueve
#                                            # este nodo a ACTIVO (no toca al peer)
# ============================================================================
param(
  [switch]$Force,
  [switch]$PromoteLocalOnly
)
$ErrorActionPreference = 'Stop'
$ClusterCfg = 'C:\Supervisor\cluster.config'
$Tasks      = @('WebConfigSync','IISSync','IISSync-Apply')

function Read-Cfg([string]$path){
  $h = @{}
  foreach ($ln in (Get-Content -LiteralPath $path)) {
    if ($ln -match '^\s*([^#=]+?)\s*=\s*(.*)$') { $h[$Matches[1].Trim()] = $Matches[2].Trim() }
  }
  return $h
}
function Set-RoleInFile([string]$path,[string]$role){
  $lines = @(Get-Content -LiteralPath $path)
  if ($lines -match '^\s*Role\s*=') { $lines = $lines -replace '^\s*Role\s*=.*', "Role=$role" }
  else { $lines += "Role=$role" }
  Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
}
function Restart-LocalTasks {
  foreach ($t in $Tasks) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
      Stop-ScheduledTask  -TaskName $t -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 600
      Start-ScheduledTask -TaskName $t
    }
  }
}

if (-not (Test-Path -LiteralPath $ClusterCfg)) { throw "No existe $ClusterCfg. Instala primero con Instalar.bat." }
$cfg  = Read-Cfg $ClusterCfg
$Peer = $cfg['Peer']
$cur  = $cfg['Role']; if ([string]::IsNullOrWhiteSpace($cur)) { $cur = 'Active' }
if ([string]::IsNullOrWhiteSpace($Peer)) { throw "cluster.config no tiene Peer=. Reinstala con Instalar.bat." }

$newLocal = if ($cur -ieq 'Active') { 'Passive' } else { 'Active' }
$newPeer  = if ($newLocal -ieq 'Active') { 'Passive' } else { 'Active' }

Write-Host ""
Write-Host "Nodo local ($env:COMPUTERNAME):  $cur  ->  $newLocal"
if (-not $PromoteLocalOnly) { Write-Host "Nodo peer  ($Peer):  ->  $newPeer" }
else { Write-Host "Modo PromoteLocalOnly: el peer ($Peer) NO se toca (se asume caido)." }
Write-Host ""
if ($newLocal -ieq 'Active') {
  Write-Host "ATENCION: tras esto, ESTE nodo ($env:COMPUTERNAME) sera el ACTIVO y EMPUJARA sus datos"
  Write-Host "sobre el pasivo. Confirma que ESTE nodo tiene la copia BUENA de los datos."
}
if (-not $Force) {
  $ans = Read-Host "Confirmas invertir roles? (S/N)"
  if ($ans -notmatch '^[sS]') { Write-Host "Cancelado. Nada cambio."; return }
}

# 1) Peer config (best-effort, salvo PromoteLocalOnly)
$peerCfgUNC = "\\$Peer\C`$\Supervisor\cluster.config"
if (-not $PromoteLocalOnly) {
  try {
    if (Test-Path -LiteralPath $peerCfgUNC) {
      Set-RoleInFile $peerCfgUNC $newPeer
      Write-Host "[ok] cluster.config del peer actualizado (Role=$newPeer)."
    } else {
      Write-Host "[AVISO] No alcanzo el cluster.config del peer ($peerCfgUNC). Si el peer esta caido usa -PromoteLocalOnly,"
      Write-Host "        o cuando vuelva corre alla Invertir-Roles.ps1 -Force para dejarlo en Passive."
    }
  } catch {
    Write-Host "[AVISO] No pude escribir el config del peer: $($_.Exception.Message)"
  }
}

# 2) Local config + restart
Set-RoleInFile $ClusterCfg $newLocal
Write-Host "[ok] cluster.config local actualizado (Role=$newLocal). Reiniciando tareas locales..."
Restart-LocalTasks
Write-Host "[ok] Tareas locales reiniciadas (tomaron Role=$newLocal)."

# 3) Reiniciar tareas del peer (best-effort)
if (-not $PromoteLocalOnly) {
  $peerOk = $true
  foreach ($t in $Tasks) {
    try {
      & schtasks /End /S $Peer /TN $t 2>&1 | Out-Null
      Start-Sleep -Milliseconds 400
      & schtasks /Run /S $Peer /TN $t 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { $peerOk = $false }
    } catch { $peerOk = $false }
  }
  if ($peerOk) { Write-Host "[ok] Tareas del peer ($Peer) reiniciadas remotamente." }
  else {
    Write-Host "[AVISO] No pude reiniciar las tareas del peer remotamente (firewall/credenciales)."
    Write-Host "        En el peer ($Peer) corre: Reiniciar-Tareas.bat  (reinicia sin volver a invertir)."
  }
}

$activeNode = if ($newLocal -ieq 'Active') { $env:COMPUTERNAME } else { $Peer }
Write-Host ""
Write-Host "LISTO. Sentido actual de la replica: ACTIVO = $activeNode  (empuja al otro)."
Write-Host "Verifica el log: C:\Supervisor\logs\webconfig_sync.log (debe decir ROL=ACTIVO en el nodo que manda)."
