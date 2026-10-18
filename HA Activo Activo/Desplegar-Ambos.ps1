# ============================================================================
#  Elaborado por SYSDOP LLC
# ----------------------------------------------------------------------------
#  Desplegar-Ambos.ps1  -  OPCIONAL. Corre UNA vez (en el PRIMARIO, elevado) y
#  deja configurados LOS DOS servidores. Requiere WinRM activo en el peer
#  (Server 2025 lo trae activo por defecto en dominio). Si falla, usa
#  Instalar.bat en cada server (plan A, por nodo: te pregunta lo necesario).
#
#  Uso:
#     .\Desplegar-Ambos.ps1 -Peer '198.51.100.30' -LocalAddr '192.0.2.10' -InfraPass '...'
#  -Peer      = IP o nombre del OTRO servidor (donde se instala por WinRM).
#  -LocalAddr = IP o nombre de ESTE servidor, tal como el peer lo alcanza
#               (es el "peer" desde el punto de vista del otro nodo).
#  Este nodo se instala como PRIMARIO de llaves IIS; el peer como secundario.
# ============================================================================
param(
  [string]$User = ".\svc-supervisor",
  [Parameter(Mandatory=$true)][string]$InfraPass,
  [Parameter(Mandatory=$true)][string]$Peer,        # el OTRO servidor
  [Parameter(Mandatory=$true)][string]$LocalAddr,   # este server visto por el peer
  [ValidateSet('DryRun','Live')][string]$IISMode = 'DryRun'
)
$ErrorActionPreference = 'Stop'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path

# 1) Instalar localmente (este server = PRIMARIO de llaves IIS)
Write-Host "=== Instalando LOCAL ($env:COMPUTERNAME), peer=$Peer, PRIMARIO ==="
& (Join-Path $here 'Instalar.ps1') -User $User -InfraPass $InfraPass -Peer $Peer -IsPrimary -IISMode $IISMode

# 2) Copiar el paquete al peer y ejecutar su instalador via WinRM (peer = SECUNDARIO)
Write-Host ""
Write-Host "=== Desplegando en PEER $peer (su peer sera $LocalAddr) ==="
$pass = ConvertTo-SecureString $InfraPass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($User, $pass)

$dst = "\\$Peer\C`$\Supervisor"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
foreach ($f in 'Sync-WebConfig.ps1','Sync-IIS.ps1','Instalar.ps1') {
  Copy-Item -Path (Join-Path $here $f) -Destination $dst -Force
}

Invoke-Command -ComputerName $Peer -Credential $cred -ScriptBlock {
  param($u,$p,$peerOfRemote,$mode)
  & 'C:\Supervisor\Instalar.ps1' -User $u -InfraPass $p -Peer $peerOfRemote -IISMode $mode
} -ArgumentList $User, $InfraPass, $LocalAddr, $IISMode

Write-Host ""
Write-Host "==== AMBOS servidores configurados. ===="
