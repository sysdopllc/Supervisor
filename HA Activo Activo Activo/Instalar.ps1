# ============================================================================
#  Elaborado por SYSDOP LLC
# ----------------------------------------------------------------------------
#  Instalar.ps1  (MODO MALLA Activo-Activo-Activo, 2 o MAS NODOS)
#  Deja todo listo en ESTE servidor (correr en CADA nodo de la malla).
#    1. Habilita acceso C$ a cuentas locales (LocalAccountTokenFilterPolicy=1)
#    2. Abre File and Printer Sharing (SMB) en el firewall
#    3. HARD CHECK del usuario local (existe, habilitado, admin; aviso GPO)
#    4. Copia los motores a C:\Supervisor (y limpia baselines viejos)
#    5. Registra la tarea "WebConfigSync" (replica de carpetas/archivos a TODOS los peers)
#    6. Registra las tareas IIS "IISSync"/"IISSync-Apply" (config IIS; arranca en DryRun)
#    7. (Re)arranca las tareas para cargar los motores nuevos.
#
#  TOPOLOGIA MALLA (Activo-Activo-Activo):
#    - TODOS los nodos son ACTIVOS. Cada uno replica bidireccional en tiempo real
#      con CADA uno de los otros. Gana el mas reciente por archivo. No hay pasivos.
#
#  Uso (PowerShell ELEVADO). Ejemplo malla de 3 nodos (correr en cada uno).
#  Sin -InfraPass, el script pide el password OCULTO:
#     # NODO 1 (primario de llaves IIS): sus peers son el 2 y el 3
#     .\Instalar.ps1 -Peers 'NODO2,NODO3' -IsPrimary
#     # NODO 2: sus peers son el 1 y el 3; el primario de llaves es el NODO 1
#     .\Instalar.ps1 -Peers 'NODO1,NODO3' -KeyPrimary 'NODO1'
#     # NODO 3: sus peers son el 1 y el 2; el primario de llaves es el NODO 1
#     .\Instalar.ps1 -Peers 'NODO1,NODO2' -KeyPrimary 'NODO1'
#  -Peers      = IP/nombre de los OTROS servidores de la malla, SEPARADOS POR COMA (obligatorio).
#  -IsPrimary  = ponlo SOLO en UN nodo (fuente de llaves de cifrado IIS). Instalalo PRIMERO.
#  -KeyPrimary = (en los NO primarios) IP/nombre del nodo primario, para sincronizar llaves IIS.
#  -InfraPass  = opcional (despliegue por script). Si no se da, se pide OCULTO.
# ============================================================================
param(
  [string]$User = ".\svc-supervisor",
  [string]$InfraPass = '',                                    # vacio = se pide OCULTO al correr (recomendado)
  [Parameter(Mandatory=$true)][string]$Peers,                 # OTROS servidores de la malla, separados por coma
  [switch]$IsPrimary,                                         # $true SOLO en 1 nodo (fuente de llaves IIS)
  [string]$KeyPrimary = '',                                   # (no primarios) nodo primario de llaves IIS
  [ValidateSet('DryRun','Live')][string]$IISMode = 'DryRun'   # DryRun = solo prueba (no aplica) | Live = replica real
)
$ErrorActionPreference = 'Stop'
$dest = 'C:\Supervisor'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ESTE servidor por nombre, loopback o cualquiera de sus IPs: nunca se toma como peer
# (evita replicar contra si mismo por un dato mal tecleado).
function Test-EsEsteServidor([string]$h) {
  $h = "$h".Trim()
  if ([string]::IsNullOrWhiteSpace($h)) { return $false }
  if (($h -split '\.')[0] -ieq $env:COMPUTERNAME) { return $true }
  if (@('localhost','127.0.0.1','::1') -contains $h) { return $true }
  $ips = @(Get-NetIPAddress -ErrorAction SilentlyContinue | ForEach-Object { ($_.IPAddress -split '%')[0] })
  return ($ips -contains $h)
}

# El password de la cuenta de las tareas NO viaja por la linea de comandos: si no vino
# por -InfraPass se pide aqui OCULTO y se valida contra Windows ANTES de tocar nada.
# Asi no queda en pantalla, en el historial ni en la auditoria de procesos (4688,
# Sysmon, EDR), y un Enter en blanco ya no deja la instalacion a medias.
function ConvertFrom-PassSegura([Security.SecureString]$s) {
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Test-CredencialCuenta([string]$u, [string]$p) {
  # 'OK' = password correcto | 'MAL' = usuario o password incorrecto | otro texto = no se pudo comprobar
  try {
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
    $dom  = if ($u -match '\\') { $u.Split('\')[0] } else { '' }
    $name = if ($u -match '\\') { $u.Split('\')[-1] } else { $u }
    $ctxType = [System.DirectoryServices.AccountManagement.ContextType]::Machine
    $ctxName = $env:COMPUTERNAME
    if (-not ($dom -eq '' -or $dom -eq '.' -or $dom -ieq $env:COMPUTERNAME)) {
      $ctxType = [System.DirectoryServices.AccountManagement.ContextType]::Domain
      $ctxName = $dom
    }
    $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext($ctxType, $ctxName)
    try { if ($ctx.ValidateCredentials($name, $p)) { 'OK' } else { 'MAL' } }
    finally { $ctx.Dispose() }
  } catch { "$($_.Exception.Message)".Trim() }
}

# Los PEERS los indica quien instala (Instalar.bat los pregunta). Ya NO se hardcodean
# IPs: el mismo paquete sirve para cualquier conjunto de servidores de la misma red.
$PeerList = @($Peers -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
$PeerList = @($PeerList | Where-Object { -not (Test-EsEsteServidor $_) })   # nunca incluir este mismo nodo (nombre o IP)
if ($PeerList.Count -eq 0) { throw "Falta -Peers (IP o nombre de los OTROS servidores de la malla, separados por coma)." }
foreach ($pr in $PeerList) { if ($pr -ieq $env:COMPUTERNAME) { throw "-Peers incluye ESTE mismo servidor ($pr). Indica solo los OTROS nodos." } }
$PeersJoined = ($PeerList -join ',')
Write-Host "Malla: este nodo ($env:COMPUTERNAME) replica con: $($PeerList -join ', ')"

# --- Password de la cuenta de las tareas: se pide y valida ANTES de tocar nada ---
Write-Host "Cuenta de las tareas: $User"
$cuentaNombre = if ($User -match '\\') { $User.Split('\')[-1] } else { $User }
$cuentaPfx    = if ($User -match '\\') { $User.Split('\')[0] } else { '' }
if ($cuentaPfx -eq '' -or $cuentaPfx -eq '.' -or $cuentaPfx -ieq $env:COMPUTERNAME) {
  $cuentaLocal = Get-LocalUser -Name $cuentaNombre -ErrorAction SilentlyContinue
  if (-not $cuentaLocal)         { throw "El usuario LOCAL '$cuentaNombre' NO existe en este equipo. Crealo (MISMO nombre y password en todos los nodos) y vuelve a correr Instalar.bat." }
  if (-not $cuentaLocal.Enabled) { throw "El usuario local '$cuentaNombre' esta DESHABILITADO. Habilitalo y vuelve a correr Instalar.bat." }
}
$passPorParametro = -not [string]::IsNullOrEmpty($InfraPass)
$intentos = if ($passPorParametro) { 1 } else { 3 }
$passOk = $false
for ($n = 1; $n -le $intentos; $n++) {
  if (-not $passPorParametro) {
    $InfraPass = ConvertFrom-PassSegura (Read-Host -Prompt "Password de $User (no se muestra al escribir)" -AsSecureString)
    if ([string]::IsNullOrEmpty($InfraPass)) { Write-Host "      El password no puede ir vacio (intento $n de $intentos)."; continue }
  }
  $chk = Test-CredencialCuenta $User $InfraPass
  if ($chk -eq 'OK')  { Write-Host "      Password verificado para $User."; $passOk = $true; break }
  if ($chk -eq 'MAL') { Write-Host "      Usuario o password INCORRECTO para $User (intento $n de $intentos). Cada intento fallido cuenta para el bloqueo de la cuenta."; continue }
  Write-Host "      AVISO: no se pudo comprobar el password contra Windows ($chk). Se continua; el Programador de tareas lo valida al registrar."
  $passOk = $true; break
}
if (-not $passOk) { throw "No se obtuvo un password valido para $User. No se modifico nada en este servidor; vuelve a correr Instalar.bat." }

Write-Host "[1/7] LocalAccountTokenFilterPolicy=1 (C$ para cuentas locales)..."
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
  if (-not $lu)          { throw "HARD CHECK FALLO: el usuario LOCAL '$acctName' NO existe en este equipo. Crealo (MISMO nombre y password en TODOS los nodos)." }
  if (-not $lu.Enabled)  { throw "HARD CHECK FALLO: el usuario local '$acctName' esta DESHABILITADO." }
  $adminMembers = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue
  $inAdmin = $adminMembers | Where-Object { ($_.Name -split '\\')[-1] -ieq $acctName }
  if (-not $inAdmin)     { throw "HARD CHECK FALLO: '$acctName' NO esta en Administradores locales." }
  Write-Host "      OK: usuario local '$acctName' existe, habilitado y es admin local."
  if ($lu.PasswordExpires) { Write-Host "      AVISO: el password de '$acctName' EXPIRA el $($lu.PasswordExpires). Para un servicio conviene 'PasswordNeverExpires'." }
  Write-Host "      Miembros actuales de 'Administrators' (confirma que una GPO Restricted Groups no borre a '$acctName' tras un gpupdate):"
  $adminMembers | ForEach-Object { Write-Host ("        - " + $_.Name) }
  Write-Host "      IMPORTANTE: el MISMO usuario '$acctName' (igual nombre y password) debe existir en TODOS los nodos,"
  Write-Host "      y NO ser gestionado por una politica de dominio (Restricted Groups / 'Deny log on as a batch job')."
  # Test SMB a cada peer (no fatal: los otros nodos pueden no estar instalados todavia)
  foreach ($pr in $PeerList) {
    if (Test-Path "\\$pr\C$") { Write-Host "      C$ del peer $pr accesible (SMB OK)." }
    else { Write-Host "      AVISO: C$ del peer $pr aun no accesible (instala ese nodo, o revisa firewall/usuario/password)." }
  }
} else {
  Write-Host "      Cuenta de dominio ($User): el hard check de usuario local no aplica."
}

Write-Host "[4/7] Copiando motores a $dest ..."
New-Item -ItemType Directory -Path $dest -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dest 'logs') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dest 'state') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dest 'incoming') -Force | Out-Null
# cluster.config: lo LEEN los motores (Sync-WebConfig / Sync-IIS) para saber con
# que servidores replicar. Escrito por el instalador -> sin IPs hardcodeadas.
$clusterCfg = Join-Path $dest 'cluster.config'
@(
  "# Generado por Instalar.bat - Elaborado por SYSDOP LLC"
  "# Peers = los OTROS servidores de la malla (Activo-Activo-Activo), separados por coma."
  "# Topologia MALLA: todos activos, replica bidireccional en tiempo real con cada peer."
  "Peers=$PeersJoined"
  "LocalName=$env:COMPUTERNAME"
  "IsPrimary=$([bool]$IsPrimary)"
  "KeyPrimary=$KeyPrimary"
) | Set-Content -LiteralPath $clusterCfg -Encoding UTF8
Write-Host "      cluster.config escrito (Peers=$PeersJoined, IsPrimary=$([bool]$IsPrimary))."
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

# --- Sincroniza las LLAVES de cifrado de IIS entre TODOS los nodos ---------------
# Asi el applicationHost.config replicado (con passwords de app pool cifrados) se
# descifra en TODOS. Un nodo es PRIMARIO (-IsPrimary): fuente de llaves. Cada nodo NO
# primario adopta las llaves del PRIMARIO (indicado en -KeyPrimary) SOLO si difieren,
# con backup y validacion (si algo falla, restaura). Si son clones y ya coinciden, no
# toca nada.
$AppHostCfgPath = "$env:windir\System32\inetsrv\config\applicationHost.config"
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
    Write-Host "      Primario de llaves IIS ($env:COMPUTERNAME): llaves exportadas a $keysDir (corre luego los OTROS nodos con -KeyPrimary $env:COMPUTERNAME para sincronizar)."
    return
  }
  # NO PRIMARIO: adopta las llaves del primario indicado en -KeyPrimary.
  $src = if ($KeyPrimary) { $KeyPrimary } else { $PeerList[0] }
  if (-not $KeyPrimary) { Write-Host "      AVISO: no se indico -KeyPrimary; usando el primer peer ($src) como fuente de llaves. Indica el nodo que instalaste con -IsPrimary." }
  $peerKeys = "\\$src\C$\Supervisor\keys"
  if (-not (Test-Path $peerKeys)) { Write-Host "      AVISO: corre primero Instalar.bat en el PRIMARIO ($src, con -IsPrimary) y luego re-corre aqui para sincronizar llaves IIS."; return }
  $differ = $false
  foreach ($k in $keys) { $mine = Join-Path $keysDir "$k.xml"; $pk = Join-Path $peerKeys "$k.xml"
    if ((Test-Path $pk) -and (Test-Path $mine) -and ((Get-Content -Raw $mine) -ne (Get-Content -Raw $pk))) { $differ = $true } }
  if (-not $differ) {
    Write-Host "      Llaves de cifrado IIS ya coinciden con el primario $src (clones) -> replica segura, sin cambios."
  } else {
    Write-Host "      Llaves IIS DIFIEREN del primario $src -> sincronizando con backup..."
    $kbak = Join-Path $dest ("state\iiskeys-bak-{0:yyyyMMdd-HHmmss}" -f (Get-Date)); New-Item -ItemType Directory -Path $kbak -Force | Out-Null
    Copy-Item $AppHostCfgPath (Join-Path $kbak 'applicationHost.config') -Force -ErrorAction SilentlyContinue
    foreach ($k in $keys) { & $aspnet -px $k (Join-Path $kbak "$k.xml") -pri 2>&1 | Out-Null }            # backup de MIS llaves
    foreach ($k in $keys) { & $aspnet -pi $k (Join-Path $peerKeys "$k.xml") 2>&1 | Out-Null }             # importa las del primario
    Copy-Item "\\$src\C$\Windows\System32\inetsrv\config\applicationHost.config" $AppHostCfgPath -Force -ErrorAction SilentlyContinue
    & "$env:windir\System32\inetsrv\appcmd.exe" list config 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "      ERROR: la validacion fallo -> RESTAURANDO llaves y config previos (no se limpia)."
      foreach ($k in $keys) { & $aspnet -pi $k (Join-Path $kbak "$k.xml") 2>&1 | Out-Null }
      Copy-Item (Join-Path $kbak 'applicationHost.config') $AppHostCfgPath -Force -ErrorAction SilentlyContinue
      return
    }
    Write-Host "      Llaves IIS sincronizadas con el primario $src y config adoptada. OK (backup en $kbak)."
  }
  Remove-Item $keysDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "      Llaves IIS locales exportadas BORRADAS (higiene). Cuando TODOS los nodos esten sincronizados, borra tambien C:\Supervisor\keys del primario."
}
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

Write-Host "[5/7] Registrando tarea WebConfigSync (replica de archivos a todos los peers, usuario $User)..."
Register-SyncTask 'WebConfigSync' 'Sync-WebConfig.ps1'

Write-Host "[6/7] Registrando tareas IIS (Pusher=usuario local por SMB, Applier=SYSTEM aplica local)..."
$iisTasks = @()
if (Test-Path (Join-Path $dest 'Sync-IIS.ps1')) {
  Register-SyncTask 'IISSync'       'Sync-IIS.ps1' ' -Role Pusher'              # empuja mi config a cada peer (usuario local)
  Register-SyncTask 'IISSync-Apply' 'Sync-IIS.ps1' ' -Role Applier' -AsSystem   # aplica la config entrante (SYSTEM: puede cifrar app pools)
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
Write-Host "LISTO en este servidor.  MODO MALLA Activo-Activo-Activo."
Write-Host "  Este nodo ($env:COMPUTERNAME) replica en tiempo real con: $($PeerList -join ', ')"
Write-Host "  - Replica de archivos: C:\Supervisor\logs\webconfig_sync.log"
Write-Host "  - Replica de IIS (DryRun): C:\Supervisor\logs\iis_sync.log"
Write-Host ""
Write-Host "IMPORTANTE IIS: Sync-IIS arranca en MODO DryRun (solo registra lo que haria, NO aplica)."
Write-Host "Valida el log iis_sync.log en TODOS los nodos y recien entonces cambia \$Mode='Live' en"
Write-Host "C:\Supervisor\Sync-IIS.ps1 (y reinicia la tarea IISSync) para activar la replica real."
Write-Host "Repite EXACTAMENTE lo mismo en cada nodo de la malla (instala el -IsPrimary PRIMERO)."
