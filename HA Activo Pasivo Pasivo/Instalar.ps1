# ============================================================================
#  Elaborado por SYSDOP LLC
# ----------------------------------------------------------------------------
#  Instalar.ps1  (MODO A>P>P, Activo > Pasivo1 > Pasivo2, 3 NODOS EN CADENA)
#  Deja todo listo en ESTE servidor (correr en el ACTIVO, el PASIVO1 y el PASIVO2).
#    0. Pide el password de la cuenta OCULTO y lo valida (si falla, no toca nada)
#    1. Habilita acceso C$ a cuentas locales (LocalAccountTokenFilterPolicy=1)
#    2. Abre File and Printer Sharing (SMB) en el firewall
#    3. HARD CHECK del usuario local (existe, habilitado, admin; aviso GPO)
#    4. Copia los motores a C:\Supervisor (y limpia baselines viejos)
#    5. Registra la tarea "WebConfigSync" (replica de carpetas/archivos)
#    6. Registra la tarea "IISSync" (replica de config IIS; arranca en DryRun)
#    7. Si das -Tertiary, registra "HASyncDaily" (rafaga diaria al 3er nodo)
#    8. (Re)arranca las tareas para cargar los motores nuevos.
#
#  TOPOLOGIA A>P>P (cadena):
#    - Activo  -> Pasivo1 : replica UNIDIRECCIONAL en TIEMPO REAL (inmediata).
#    - Pasivo1 -> Pasivo2 : RAFAGA DIARIA a una hora fija (def. 23:00). La envia el
#                           nodo que tiene -Tertiary: el que tiene ruta SMB (TCP 445)
#                           al 3er nodo, normalmente el Pasivo1. El Pasivo2 es DR/respaldo.
#    Ningun pasivo copia de vuelta al Activo. Para invertir Activo<->Pasivo1:
#    Invertir-Roles.bat (la rafaga sigue saliendo del nodo que tiene -Tertiary).
#
#  Uso (PowerShell ELEVADO). Sin -InfraPass, el script pide el password OCULTO:
#     # ACTIVO (primario de llaves IIS; se instala PRIMERO):
#     .\Instalar.ps1 -Peer 'IP-PASIVO1' -Role Active -IsPrimary
#     # PASIVO1 (recibe en tiempo real y reenvia la rafaga diaria al Pasivo2):
#     .\Instalar.ps1 -Peer 'IP-ACTIVO' -Role Passive -Tertiary 'IP-PASIVO2' -TertiaryTime '23:00'
#     # PASIVO2 (3er nodo, recibe la rafaga diaria del Pasivo1):
#     .\Instalar.ps1 -Peer 'IP-PASIVO1' -Role Passive
#  -Peer         = IP/nombre del nodo con el que se relaciona ESTE nodo: en el Activo el
#                  Pasivo1, en el Pasivo1 el Activo, en el Pasivo2 el Pasivo1.
#  -Role         = Active (empuja) | Passive (solo recibe).
#  -Tertiary     = IP/nombre del 3er nodo al que ESTE nodo envia la rafaga diaria. Solo
#                  en el nodo con ruta SMB (TCP 445) al 3er nodo. Vacio = ninguno.
#  -TertiaryTime = hora HH:mm de la rafaga diaria (def. 23:00).
#  -IsPrimary    = ponlo en el PRIMER servidor que instalas (fuente de llaves IIS).
#  -InfraPass    = opcional (despliegue por script). Si no se da, se pide OCULTO.
# ============================================================================
param(
  [string]$User = ".\svc-supervisor",
  [string]$InfraPass = '',                                    # vacio = se pide OCULTO al correr (recomendado)
  [Parameter(Mandatory=$true)][string]$Peer,                  # Activo<->Pasivo1 (tiempo real); en el Pasivo2, el Pasivo1
  [ValidateSet('Active','Passive')][string]$Role = 'Active',  # A>P: Active EMPUJA, Passive solo RECIBE
  [string]$Tertiary = '',                                     # 3er nodo al que ESTE nodo envia la rafaga diaria (vacio = ninguno)
  [string]$TertiaryTime = '23:00',                            # hora HH:mm de la rafaga diaria
  [switch]$IsPrimary,                                         # $true en el 1er server (fuente de llaves IIS)
  [ValidateSet('DryRun','Live')][string]$IISMode = 'DryRun'   # DryRun = solo prueba (no aplica) | Live = replica real
)
$ErrorActionPreference = 'Stop'
$dest = 'C:\Supervisor'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ESTE servidor por nombre, loopback o cualquiera de sus IPs: no se acepta como peer
# ni como 3er nodo (evita replicar contra si mismo por un dato mal tecleado).
function Test-EsEsteServidor([string]$h) {
  $h = "$h".Trim()
  if ([string]::IsNullOrWhiteSpace($h)) { return $false }
  if (($h -split '\.')[0] -ieq $env:COMPUTERNAME) { return $true }
  if (@('localhost','127.0.0.1','::1') -contains $h) { return $true }
  $ips = @(Get-NetIPAddress -ErrorAction SilentlyContinue | ForEach-Object { ($_.IPAddress -split '%')[0] })
  return ($ips -contains $h)
}

# Conectividad TCP 445 (SMB) con espera corta; no autentica ni toca el otro nodo.
function Test-Puerto445([string]$h) {
  $c = New-Object System.Net.Sockets.TcpClient
  try { $ar = $c.BeginConnect($h, 445, $null, $null); ($ar.AsyncWaitHandle.WaitOne(3000) -and $c.Connected) }
  catch { $false }
  finally { $c.Close() }
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

# El PEER lo indica quien instala (Instalar.bat lo pregunta). Ya NO se hardcodean
# IPs: el mismo paquete sirve para cualquier trio de servidores de la misma red.
$Peer = $Peer.Trim()
if ([string]::IsNullOrWhiteSpace($Peer)) { throw "Falta -Peer (IP o nombre del OTRO servidor)." }
if (Test-EsEsteServidor $Peer) { throw "-Peer ($Peer) es ESTE mismo servidor. Indica el OTRO nodo." }
$Tertiary = "$Tertiary".Trim()
if ($Tertiary -and (Test-EsEsteServidor $Tertiary)) { throw "-Tertiary ($Tertiary) es ESTE mismo servidor. El 3er nodo debe ser OTRO servidor." }
if ($Tertiary -and ($Tertiary -ieq $Peer)) { throw "-Tertiary ($Tertiary) es el mismo nodo que -Peer. La rafaga diaria va a un 3er servidor distinto, nunca de vuelta al peer." }
if ($TertiaryTime -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') {
  if ($Tertiary) { Write-Host "AVISO: hora de rafaga '$TertiaryTime' no valida (HH:mm); se usa 23:00." }
  $TertiaryTime = '23:00'
}

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
  if (-not $lu)          { throw "HARD CHECK FALLO: el usuario LOCAL '$acctName' NO existe en este equipo. Crealo (MISMO nombre y password en todos los nodos)." }
  if (-not $lu.Enabled)  { throw "HARD CHECK FALLO: el usuario local '$acctName' esta DESHABILITADO." }
  $adminMembers = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue
  $inAdmin = $adminMembers | Where-Object { ($_.Name -split '\\')[-1] -ieq $acctName }
  if (-not $inAdmin)     { throw "HARD CHECK FALLO: '$acctName' NO esta en Administradores locales." }
  Write-Host "      OK: usuario local '$acctName' existe, habilitado y es admin local."
  if ($lu.PasswordExpires) { Write-Host "      AVISO: el password de '$acctName' EXPIRA el $($lu.PasswordExpires). Para un servicio conviene 'PasswordNeverExpires'." }
  Write-Host "      Miembros actuales de 'Administrators' (confirma que una GPO Restricted Groups no borre a '$acctName' tras un gpupdate):"
  $adminMembers | ForEach-Object { Write-Host ("        - " + $_.Name) }
  Write-Host "      IMPORTANTE: el MISMO usuario '$acctName' (igual nombre y password) debe existir en el peer (y en el 3er nodo si este nodo le envia la rafaga),"
  Write-Host "      y NO ser gestionado por una politica de dominio (Restricted Groups / 'Deny log on as a batch job')."
  # Test SMB al peer (no fatal: el otro server puede no estar instalado todavia)
  if (Test-Path "\\$Peer\C$") { Write-Host "      C$ del peer $Peer accesible (SMB OK)." }
  else { Write-Host "      AVISO: C$ del peer $Peer aun no accesible (instala primero el otro server, o revisa firewall/usuario/password)." }
} else {
  Write-Host "      Cuenta de dominio ($User): el hard check de usuario local no aplica."
}
if ($Tertiary) {
  # Ruta de red al 3er nodo (no fatal): se avisa ya, no a la hora de la rafaga.
  if (Test-Puerto445 $Tertiary) { Write-Host "      3er nodo $Tertiary responde en TCP 445 (SMB) desde este servidor." }
  else { Write-Host "      AVISO: el 3er nodo $Tertiary NO responde en TCP 445 desde este servidor (firewall/ruta). La rafaga fallara; configurala en el nodo que SI llega al 3er nodo (normalmente el Pasivo1)." }
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
  "# Peer = nodo con el que se relaciona ESTE nodo (Activo<->Pasivo1; en el Pasivo2, el Pasivo1)."
  "# Role = Active (empuja en tiempo real) | Passive (recibe; nunca copia de vuelta)."
  "# Tertiary = 3er nodo al que ESTE nodo envia la RAFAGA DIARIA (vacio = ninguno)."
  "# TertiaryTime = hora HH:mm de la rafaga diaria. Topologia A>P>P en cadena."
  "Peer=$Peer"
  "Role=$Role"
  "Tertiary=$Tertiary"
  "TertiaryTime=$TertiaryTime"
  "LocalName=$env:COMPUTERNAME"
  "IsPrimary=$([bool]$IsPrimary)"
) | Set-Content -LiteralPath $clusterCfg -Encoding UTF8
Write-Host "      cluster.config escrito (Peer=$Peer, Role=$Role, Tertiary=$Tertiary, TertiaryTime=$TertiaryTime, IsPrimary=$([bool]$IsPrimary))."
# La replica de IIS aplica LOCAL (cada nodo se configura a si mismo) y transfiere el
# estado por SMB (C$). NO usa WinRM ni guarda passwords -> no hay error 0x80070520.
Copy-Item -Path (Join-Path $here 'Sync-WebConfig.ps1') -Destination $dest -Force
if (Test-Path (Join-Path $here 'Sync-Daily.ps1')) { Copy-Item -Path (Join-Path $here 'Sync-Daily.ps1') -Destination $dest -Force }
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
    # Si ese peer reenvia la rafaga a un 3er nodo (Tertiary= en su cluster.config), sus llaves
    # exportadas NO se borran: las necesita el 3er nodo, que las borra al instalarse.
    $sk = "\\$Peer\C$\Supervisor\keys"; $bothOk = (Test-Path $sk)
    if ($bothOk) { foreach ($k in $keys) { $m = Join-Path $keysDir "$k.xml"; $p = Join-Path $sk "$k.xml"
      if (-not (Test-Path $p) -or ((Get-Content -Raw $m) -ne (Get-Content -Raw $p))) { $bothOk = $false } } }
    $peerReenvia = $false
    try { $peerReenvia = [bool](Get-Content -LiteralPath "\\$Peer\C$\Supervisor\cluster.config" -ErrorAction Stop | Where-Object { $_ -match '^\s*Tertiary\s*=\s*\S' }) } catch { }
    if ($bothOk -and $peerReenvia) { Remove-Item $keysDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "      Llaves IIS ya sincronizadas con $Peer -> las de este nodo BORRADAS; las de $Peer quedan para su 3er nodo." }
    elseif ($bothOk) { Remove-Item $keysDir, $sk -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "      Llaves IIS ya sincronizadas en ambos -> llaves exportadas BORRADAS (higiene)." }
    else { Write-Host "      Primario de llaves IIS ($env:COMPUTERNAME): llaves exportadas (corre luego el SECUNDARIO para sincronizar)." }
    return
  }
  # SECUNDARIO:
  $peerKeys = "\\$Peer\C$\Supervisor\keys"
  if (-not (Test-Path $peerKeys)) { Write-Host "      AVISO: $Peer no tiene llaves IIS exportadas. Instala primero ese nodo (el ACTIVO primario; o el PASIVO1 si este es el PASIVO2) y luego re-corre aqui para sincronizar llaves IIS."; return }
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
  # Excepcion: si ESTE nodo reenvia la rafaga a un 3er nodo (-Tertiary), re-exporta SUS llaves (ya
  # iguales a las del primario) para que el 3er nodo las adopte; se borran al instalar el 3er nodo.
  if ($Tertiary) {
    foreach ($k in $keys) { $kf = Join-Path $keysDir "$k.xml"; Remove-Item $kf -Force -ErrorAction SilentlyContinue; & $aspnet -px $k $kf -pri 2>&1 | Out-Null }
    Remove-Item $peerKeys -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "      Llaves IIS del peer BORRADAS; las de este nodo quedan en $keysDir para el 3er nodo ($Tertiary). Se borran solas al instalar el 3er nodo."
  } else {
    Remove-Item $keysDir, $peerKeys -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "      Llaves IIS exportadas BORRADAS de ambos nodos (higiene)."
  }
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

# --- 3er nodo: rafaga DIARIA (en el nodo que tiene -Tertiary, sea Activo o Pasivo) ---
# Tarea HASyncDaily: dispara Sync-Daily.ps1 una vez al dia a TertiaryTime (def 23:00).
# Corre como la cuenta de las tareas (necesita SMB al 3er nodo). En la cadena A>P1>P2 va en
# el Pasivo1. Sin -Tertiary no se registra y, si quedo de una instalacion anterior, se
# elimina (este nodo deja de enviar la rafaga).
$dailyTasks = @()
if (-not [string]::IsNullOrWhiteSpace($Tertiary) -and (Test-Path (Join-Path $dest 'Sync-Daily.ps1'))) {
  $tt = if ($TertiaryTime -match '^\d{1,2}:\d{2}$') { $TertiaryTime } else { '23:00' }
  $dailyArg     = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Supervisor\Sync-Daily.ps1"'
  $dailyAction  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $dailyArg
  $dailyTrigger = New-ScheduledTaskTrigger -Daily -At $tt
  $dailySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName 'HASyncDaily' -Action $dailyAction -Trigger $dailyTrigger `
    -Settings $dailySettings -User $User -Password $InfraPass -RunLevel Highest -Force | Out-Null
  $dailyTasks = @('HASyncDaily')
  Write-Host "      HASyncDaily registrada: rafaga diaria a las $tt desde este nodo hacia el 3er nodo $Tertiary."
} elseif (-not [string]::IsNullOrWhiteSpace($Tertiary)) {
  Write-Host "      AVISO: falta Sync-Daily.ps1 en el paquete; NO se registra la rafaga diaria hacia $Tertiary."
} elseif (Get-ScheduledTask -TaskName 'HASyncDaily' -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName 'HASyncDaily' -Confirm:$false
  Write-Host "      HASyncDaily de una instalacion anterior ELIMINADA: este nodo ya no envia la rafaga diaria."
} else {
  Write-Host "      (Sin -Tertiary: este nodo no envia rafaga diaria.)"
}

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
# Las tareas continuas se arrancan ya; HASyncDaily NO se arranca ahora (dispara a su hora).
Get-ScheduledTask -TaskName (@($allTasks) + @($dailyTasks)) -ErrorAction SilentlyContinue | Get-ScheduledTaskInfo |
  Select-Object TaskName,LastTaskResult,LastRunTime,NextRunTime,NumberOfMissedRuns | Format-Table -AutoSize

Write-Host ""
Write-Host "LISTO en este servidor.  MODO A>P>P (cadena)  -  Rol de este nodo: $Role"
if ($Role -ieq 'Active') { Write-Host "  Este nodo es ACTIVO: EMPUJA en tiempo real a $Peer. Ningun pasivo copia de vuelta." }
else                     { Write-Host "  Este nodo es PASIVO: recibe de $Peer. No replica hacia el activo." }
if (-not [string]::IsNullOrWhiteSpace($Tertiary)) {
  Write-Host "  Ademas envia una RAFAGA DIARIA a las $TertiaryTime al 3er nodo ($Tertiary)."
  Write-Host "    Probar la rafaga ahora (manual): Start-ScheduledTask -TaskName HASyncDaily   (log: daily_sync.log)"
}
Write-Host "  - Replica de archivos: C:\Supervisor\logs\webconfig_sync.log"
Write-Host "  - Rafaga diaria (3er nodo): C:\Supervisor\logs\daily_sync.log"
Write-Host "  - Replica de IIS ($IISMode): C:\Supervisor\logs\iis_sync.log"
Write-Host ""
if ($IISMode -eq 'DryRun') {
  Write-Host "IMPORTANTE IIS: Sync-IIS quedo en MODO DryRun (solo registra lo que haria, NO aplica)."
  Write-Host "Valida el log iis_sync.log y luego re-corre Instalar.bat respondiendo S a 'IIS EN VIVO'"
  Write-Host "(o cambia `$Mode='Live' en C:\Supervisor\Sync-IIS.ps1 y reinicia IISSync e IISSync-Apply)."
}
Write-Host "Orden: ACTIVO (Primario=S), luego PASIVO1 (con el 3er nodo), luego PASIVO2 (peer = PASIVO1)."
Write-Host "Para invertir Activo<->Pasivo1 mas adelante: Invertir-Roles.bat (no reinstala, solo cambia el rol)."

