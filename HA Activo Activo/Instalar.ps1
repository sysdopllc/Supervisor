# ============================================================================
#  Elaborado por SYSDOP LLC
# ----------------------------------------------------------------------------
#  Instalar.ps1  -  Deja todo listo en ESTE servidor (correr en los nodos A y B).
#    1. Habilita acceso C$ a cuentas locales (LocalAccountTokenFilterPolicy=1)
#    2. Abre File and Printer Sharing (SMB) en el firewall
#    3. HARD CHECK del usuario local (existe, habilitado, admin; aviso GPO)
#    4. Copia los motores a C:\Supervisor (y limpia baselines viejos)
#    5. Registra la tarea "WebConfigSync" (replica de carpetas/archivos)
#    6. Registra la tarea "IISSync" (replica de config IIS; arranca en DryRun)
#    7. (Re)arranca ambas tareas para cargar los motores nuevos.
#
#  Uso (PowerShell ELEVADO):
#     .\Instalar.ps1 -InfraPass 'PASSWORD' -Peer '198.51.100.30' -IsPrimary
#  Opcional cuenta de dominio en vez de local:
#     .\Instalar.ps1 -User 'EXAMPLE\svc-supervisor' -InfraPass '...' -Peer 'NODE-C'
#  -Peer      = IP o NOMBRE del OTRO servidor del par (obligatorio).
#  -IsPrimary = ponlo en el PRIMER servidor que instalas (fuente de llaves IIS).
# ============================================================================
param(
  [string]$User = ".\svc-supervisor",
  [Parameter(Mandatory=$true)][string]$InfraPass,
  [Parameter(Mandatory=$true)][string]$Peer,                  # IP o nombre del OTRO servidor
  [switch]$IsPrimary,                                         # $true en el 1er server (fuente de llaves IIS)
  [ValidateSet('DryRun','Live')][string]$IISMode = 'DryRun'   # DryRun = solo prueba (no aplica) | Live = replica real
)
$ErrorActionPreference = 'Stop'
$dest = 'C:\Supervisor'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# El PEER lo indica quien instala (Instalar.bat lo pregunta). Ya NO se hardcodean
# IPs: el mismo paquete sirve para cualquier par de servidores de la misma red.
$Peer = $Peer.Trim()
if ([string]::IsNullOrWhiteSpace($Peer)) { throw "Falta -Peer (IP o nombre del OTRO servidor)." }
if ($Peer -ieq $env:COMPUTERNAME) { throw "-Peer ($Peer) es ESTE mismo servidor. Indica el OTRO nodo del par." }

Write-Host "[1/7] LocalAccountTokenFilterPolicy=1 (C$ y WinRM para cuentas locales)..."
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name 'LocalAccountTokenFilterPolicy' -Value 1 -PropertyType DWord -Force | Out-Null

Write-Host "[2/7] Firewall: File and Printer Sharing..."
Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue

Write-Host "[3/7] HARD CHECK del usuario para el servicio..."
# La replica (archivos e IIS) se mueve por SMB (C$) y se aplica LOCAL: NO usa WinRM.
# Con usuario LOCAL para servicios: verificar que sea consistente y que el dominio no lo pise.
$acctName = if ($User -match '\\') { $User.Split('\')[-1] } else { $User.TrimStart('.\') }
$pfx3 = if ($User -match '\\') { $User.Split('\')[0] } else { '' }
$isLocalAcct = ($pfx3 -eq '' -or $pfx3 -eq '.' -or $pfx3 -eq $env:COMPUTERNAME)
if ($isLocalAcct) {
  $lu = Get-LocalUser -Name $acctName -ErrorAction SilentlyContinue
  if (-not $lu)          { throw "HARD CHECK FALLO: el usuario LOCAL '$acctName' NO existe en este equipo. Crealo (MISMO nombre y password en los nodos A y B)." }
  if (-not $lu.Enabled)  { throw "HARD CHECK FALLO: el usuario local '$acctName' esta DESHABILITADO." }
  $adminMembers = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue
  $inAdmin = $adminMembers | Where-Object { ($_.Name -split '\\')[-1] -ieq $acctName }
  if (-not $inAdmin)     { throw "HARD CHECK FALLO: '$acctName' NO esta en Administradores locales." }
  Write-Host "      OK: usuario local '$acctName' existe, habilitado y es admin local."
  if ($lu.PasswordExpires) { Write-Host "      AVISO: el password de '$acctName' EXPIRA el $($lu.PasswordExpires). Para un servicio conviene 'PasswordNeverExpires'." }
  Write-Host "      Miembros actuales de 'Administrators' (confirma que una GPO Restricted Groups no borre a '$acctName' tras un gpupdate):"
  $adminMembers | ForEach-Object { Write-Host ("        - " + $_.Name) }
  Write-Host "      IMPORTANTE: el MISMO usuario '$acctName' (igual nombre y password) debe existir en el OTRO servidor,"
  Write-Host "      y NO ser gestionado por una politica de dominio (Restricted Groups / 'Deny log on as a batch job')."
  # Test SMB al peer (no fatal: el otro server puede no estar instalado todavia)
  if (Test-Path "\\$Peer\C$") { Write-Host "      C$ del peer $Peer accesible (SMB OK)." }
  else { Write-Host "      AVISO: C$ del peer $Peer aun no accesible (instala primero el otro server, o revisa firewall/usuario/password)." }
} else {
  Write-Host "      Cuenta de dominio ($User): el hard check de usuario local no aplica."
}

Write-Host "[4/7] Copiando motores a $dest ..."
New-Item -ItemType Directory -Path $dest -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dest 'logs') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dest 'state') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dest 'incoming') -Force | Out-Null
# cluster.config: lo LEEN los motores (Sync-WebConfig / Sync-IIS) para saber con
# que servidor replicar. Escrito por el instalador -> sin IPs hardcodeadas.
$clusterCfg = Join-Path $dest 'cluster.config'
@(
  "# Generado por Instalar.bat - Elaborado por SYSDOP LLC"
  "# Peer = el OTRO servidor del par de replica (IP o nombre)."
  "Peer=$Peer"
  "LocalName=$env:COMPUTERNAME"
  "IsPrimary=$([bool]$IsPrimary)"
) | Set-Content -LiteralPath $clusterCfg -Encoding UTF8
Write-Host "      cluster.config escrito (Peer=$Peer, IsPrimary=$([bool]$IsPrimary))."
# La replica de IIS aplica LOCAL (cada nodo se configura a si mismo) y transfiere el
# estado por SMB (C$). NO usa WinRM ni guarda passwords -> no hay error 0x80070520.
Copy-Item -Path (Join-Path $here 'Sync-WebConfig.ps1') -Destination $dest -Force
if (Test-Path (Join-Path $here 'Sync-IIS.ps1')) {
  Copy-Item -Path (Join-Path $here 'Sync-IIS.ps1') -Destination $dest -Force
  # Aplica el modo elegido al motor copiado (el zip viene en DryRun; aqui se fija segun -IISMode).
  $siiDest = Join-Path $dest 'Sync-IIS.ps1'
  (Get-Content -Raw -LiteralPath $siiDest) -replace "(?m)^(\s*\`$Mode\s*=\s*)'(DryRun|Live)'", "`${1}'$IISMode'" |
    Set-Content -LiteralPath $siiDest -Encoding UTF8
  Write-Host "      Sync-IIS quedo en modo: $IISMode"
}
# Limpia baselines viejos del replicador de archivos (evita falsos borrados por baseline obsoleto).
Remove-Item -Path (Join-Path $dest 'state\*.txt') -Force -ErrorAction SilentlyContinue

# --- Sincroniza las LLAVES de cifrado de IIS entre los 2 nodos -------------------
# Asi el applicationHost.config replicado (con passwords de app pool cifrados) se
# descifra en AMBOS. El PRIMARIO (el server donde corriste con -IsPrimary) es la
# fuente de llaves. El secundario adopta las llaves + config del primario SOLO si
# difieren, con backup y validacion (si algo falla, restaura). Si son clones y ya
# coinciden, no toca nada.
function Sync-IISKeys {
  $keysDir = Join-Path $dest 'keys'; New-Item -ItemType Directory -Path $keysDir -Force | Out-Null
  $aspnet = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\aspnet_regiis.exe"
  if (-not (Test-Path $aspnet)) { $aspnet = "$env:windir\Microsoft.NET\Framework\v4.0.30319\aspnet_regiis.exe" }
  if (-not (Test-Path $aspnet)) { Write-Host "      AVISO: aspnet_regiis no encontrado; llaves IIS no sincronizadas."; return }
  $keys = @('iisConfigurationKey','iisWasKey')
  foreach ($k in $keys) { & $aspnet -px $k (Join-Path $keysDir "$k.xml") -pri 2>&1 | Out-Null }   # exporta MIS llaves
  try { $acl = Get-Acl $keysDir; $acl.SetAccessRuleProtection($true,$false)
        foreach ($id in 'SYSTEM','BUILTIN\Administrators') { $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id,'FullControl','Allow'))) }
        Set-Acl $keysDir $acl } catch {}
  if ($IsPrimary) {
    # PRIMARIO: si el secundario ya tiene llaves que coinciden -> ambos sincronizados -> limpiar (higiene).
    $sk = "\\$Peer\C$\Supervisor\keys"; $bothOk = (Test-Path $sk)
    if ($bothOk) { foreach ($k in $keys) { $m = Join-Path $keysDir "$k.xml"; $p = Join-Path $sk "$k.xml"
      if (-not (Test-Path $p) -or ((Get-Content -Raw $m) -ne (Get-Content -Raw $p))) { $bothOk = $false } } }
    if ($bothOk) { Remove-Item $keysDir, $sk -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "      Llaves IIS ya sincronizadas en ambos -> llaves exportadas BORRADAS (higiene)." }
    else { Write-Host "      Primario de llaves IIS ($env:COMPUTERNAME): llaves exportadas (corre luego el SECUNDARIO para sincronizar)." }
    return
  }
  # SECUNDARIO:
  $peerKeys = "\\$Peer\C$\Supervisor\keys"
  if (-not (Test-Path $peerKeys)) { Write-Host "      AVISO: corre primero Instalar.bat en el PRIMARIO (con -IsPrimary / respondiendo S) y luego re-corre aqui para sincronizar llaves IIS."; return }
  $differ = $false
  foreach ($k in $keys) { $mine = Join-Path $keysDir "$k.xml"; $pk = Join-Path $peerKeys "$k.xml"
    if ((Test-Path $pk) -and (Test-Path $mine) -and ((Get-Content -Raw $mine) -ne (Get-Content -Raw $pk))) { $differ = $true } }
  if (-not $differ) {
    Write-Host "      Llaves de cifrado IIS ya coinciden con el primario (clones) -> replica segura, sin cambios."
  } else {
    Write-Host "      Llaves IIS DIFIEREN del primario -> sincronizando con backup..."
    $kbak = Join-Path $dest ("state\iiskeys-bak-{0:yyyyMMdd-HHmmss}" -f (Get-Date)); New-Item -ItemType Directory -Path $kbak -Force | Out-Null
    Copy-Item $AppHostCfgPath (Join-Path $kbak 'applicationHost.config') -Force -ErrorAction SilentlyContinue
    foreach ($k in $keys) { & $aspnet -px $k (Join-Path $kbak "$k.xml") -pri 2>&1 | Out-Null }            # backup de MIS llaves
    foreach ($k in $keys) { & $aspnet -pi $k (Join-Path $peerKeys "$k.xml") 2>&1 | Out-Null }             # importa las del primario
    Copy-Item "\\$Peer\C$\Windows\System32\inetsrv\config\applicationHost.config" $AppHostCfgPath -Force -ErrorAction SilentlyContinue
    & "$env:windir\System32\inetsrv\appcmd.exe" list config 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "      ERROR: la validacion fallo -> RESTAURANDO llaves y config previos (no se limpia)."
      foreach ($k in $keys) { & $aspnet -pi $k (Join-Path $kbak "$k.xml") 2>&1 | Out-Null }
      Copy-Item (Join-Path $kbak 'applicationHost.config') $AppHostCfgPath -Force -ErrorAction SilentlyContinue
      return
    }
    Write-Host "      Llaves IIS sincronizadas con el primario y config adoptada. OK (backup en $kbak)."
  }
  # El secundario es el ultimo que necesita las llaves -> borrarlas de AMBOS nodos (higiene de seguridad).
  Remove-Item $keysDir, $peerKeys -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "      Llaves IIS exportadas BORRADAS de ambos nodos (higiene)."
}
$AppHostCfgPath = "$env:windir\System32\inetsrv\config\applicationHost.config"
Write-Host "      Sincronizando llaves de cifrado de IIS (cierra la brecha de descifrado)..."
try { Sync-IISKeys } catch { Write-Host "      AVISO Sync-IISKeys: $($_.Exception.Message)" }

# Normaliza la cuenta local a EQUIPO\usuario (Register-ScheduledTask no mapea ".\usuario").
if ($User -like '.\*')         { $User = "$env:COMPUTERNAME\" + $User.Substring(2) }
elseif ($User -notmatch '\\')  { $User = "$env:COMPUTERNAME\$User" }

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

function Register-SyncTask([string]$name, [string]$script, [string]$roleArg = '', [switch]$AsSystem){
  $arg     = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Supervisor\{0}"{1}' -f $script, $roleArg)
  $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
  $trigger = New-ScheduledTaskTrigger -AtStartup
  if ($AsSystem) {
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
  } else {
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -User $User -Password $InfraPass -RunLevel Highest -Force | Out-Null
  }
}

Write-Host "[5/7] Registrando tarea WebConfigSync (replica de archivos, usuario $User)..."
Register-SyncTask 'WebConfigSync' 'Sync-WebConfig.ps1'

Write-Host "[6/7] Registrando tareas IIS (Pusher=usuario local por SMB, Applier=SYSTEM aplica local)..."
$iisTasks = @()
if (Test-Path (Join-Path $dest 'Sync-IIS.ps1')) {
  Register-SyncTask 'IISSync'       'Sync-IIS.ps1' ' -Role Pusher'              # empuja mi estado al peer (usuario local)
  Register-SyncTask 'IISSync-Apply' 'Sync-IIS.ps1' ' -Role Applier' -AsSystem   # aplica el estado entrante (SYSTEM: puede cifrar app pools)
  $iisTasks = @('IISSync','IISSync-Apply')
  Write-Host "      IIS en modo: $IISMode"
} else { Write-Host "      (Sync-IIS.ps1 no presente; se omiten tareas IIS)" }

Write-Host "[7/7] (Re)arrancando tareas..."
$allTasks = @('WebConfigSync') + $iisTasks
foreach ($t in $allTasks) {
  if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask  -TaskName $t -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600
    Start-ScheduledTask -TaskName $t
  }
}
Start-Sleep -Seconds 2
Get-ScheduledTask -TaskName $allTasks -ErrorAction SilentlyContinue | Get-ScheduledTaskInfo |
  Select-Object TaskName,LastTaskResult,LastRunTime,NumberOfMissedRuns | Format-Table -AutoSize

Write-Host ""
Write-Host "LISTO en este servidor."
Write-Host "  - Replica de archivos: C:\Supervisor\logs\webconfig_sync.log"
Write-Host "  - Replica de IIS (DryRun): C:\Supervisor\logs\iis_sync.log"
Write-Host ""
Write-Host "IMPORTANTE IIS: Sync-IIS arranca en MODO DryRun (solo registra lo que haria, NO aplica)."
Write-Host "Valida el log iis_sync.log en AMBOS servidores y recien entonces cambia \$Mode='Live' en"
Write-Host "C:\Supervisor\Sync-IIS.ps1 (y reinicia la tarea IISSync) para activar la replica real."
Write-Host "Repite EXACTAMENTE lo mismo en el otro servidor."

