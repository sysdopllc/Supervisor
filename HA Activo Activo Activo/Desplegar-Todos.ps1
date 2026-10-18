# ============================================================================
#  Elaborado por SYSDOP LLC
# ----------------------------------------------------------------------------
#  Desplegar-Todos.ps1  -  OPCIONAL. Corre UNA vez (en el nodo PRIMARIO, elevado)
#  y deja configurados TODOS los nodos de la malla via WinRM. Si WinRM no esta
#  disponible, usa Instalar.bat en cada nodo (plan A, por nodo: te pregunta todo).
#
#  Este nodo se instala como PRIMARIO de llaves IIS. Cada nodo remoto se instala
#  con su propia lista de peers = (todos los nodos MENOS el mismo) y con
#  -KeyPrimary apuntando a este nodo.
#
#  Uso:
#     .\Desplegar-Todos.ps1 -InfraPass 'PASS' -Nodes 'NODO1,NODO2,NODO3' -LocalName 'NODO1'
#  -Nodes     = TODOS los nodos de la malla (incluyendo este), separados por coma.
#  -LocalName = nombre/IP de ESTE nodo tal como los demas lo alcanzan (debe estar en -Nodes).
#               Este nodo se instala local (PRIMARIO); el resto por WinRM.
# ============================================================================
param(
  [string]$User = ".\svc-supervisor",
  [Parameter(Mandatory=$true)][string]$InfraPass,
  [Parameter(Mandatory=$true)][string]$Nodes,        # TODOS los nodos de la malla (incl. este)
  [Parameter(Mandatory=$true)][string]$LocalName,    # este nodo, como lo ven los demas
  [ValidateSet('DryRun','Live')][string]$IISMode = 'DryRun'
)
$ErrorActionPreference = 'Stop'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path

$All = @($Nodes -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if ($All.Count -lt 2) { throw "-Nodes debe listar al menos 2 nodos (idealmente 3), separados por coma." }
if ($All -notcontains $LocalName) { throw "-LocalName ($LocalName) debe estar incluido en -Nodes ($Nodes)." }

# Peers de un nodo = todos los demas.
function PeersOf([string]$node){ ($All | Where-Object { $_ -ine $node }) -join ',' }

# 1) Instalar LOCAL (este nodo = PRIMARIO de llaves IIS)
$localPeers = PeersOf $LocalName
Write-Host "=== Instalando LOCAL ($LocalName) PRIMARIO, peers=$localPeers ==="
& (Join-Path $here 'Instalar.ps1') -User $User -InfraPass $InfraPass -Peers $localPeers -IsPrimary -IISMode $IISMode

# 2) Instalar cada nodo remoto via WinRM (peers propios; KeyPrimary = este nodo)
$pass = ConvertTo-SecureString $InfraPass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($User, $pass)
foreach ($node in $All | Where-Object { $_ -ine $LocalName }) {
  $peers = PeersOf $node
  Write-Host ""
  Write-Host "=== Desplegando en $node (peers=$peers, KeyPrimary=$LocalName) ==="
  $dst = "\\$node\C`$\Supervisor"
  New-Item -ItemType Directory -Path $dst -Force | Out-Null
  foreach ($f in 'Sync-WebConfig.ps1','Sync-IIS.ps1','Instalar.ps1') {
    Copy-Item -Path (Join-Path $here $f) -Destination $dst -Force
  }
  Invoke-Command -ComputerName $node -Credential $cred -ScriptBlock {
    param($u,$p,$peers,$keyPrim,$mode)
    & 'C:\Supervisor\Instalar.ps1' -User $u -InfraPass $p -Peers $peers -KeyPrimary $keyPrim -IISMode $mode
  } -ArgumentList $User, $InfraPass, $peers, $LocalName, $IISMode
}

Write-Host ""
Write-Host "==== TODOS los nodos de la malla configurados. ===="
Write-Host "Valida iis_sync.log en cada nodo antes de pasar IIS a Live."
