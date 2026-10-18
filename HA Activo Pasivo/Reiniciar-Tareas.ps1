# ============================================================================
#  Elaborado por SYSDOP LLC
# ----------------------------------------------------------------------------
#  Reiniciar-Tareas.ps1  -  Reinicia las tareas de replica de ESTE nodo SIN
#  cambiar el rol (no invierte nada). Util cuando Invertir-Roles no pudo
#  reiniciar el peer remotamente: lo corres en el peer y este toma el rol que
#  ya quedo escrito en su cluster.config.
# ============================================================================
$ErrorActionPreference = 'Stop'
$Tasks = @('WebConfigSync','IISSync','IISSync-Apply')
$cfg = 'C:\Supervisor\cluster.config'
if (Test-Path -LiteralPath $cfg) {
  $role = (Get-Content -LiteralPath $cfg | Where-Object { $_ -match '^\s*Role\s*=' }) -replace '^\s*Role\s*=\s*',''
  Write-Host "Rol actual en cluster.config: $role"
}
foreach ($t in $Tasks) {
  if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask  -TaskName $t -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600
    Start-ScheduledTask -TaskName $t
    Write-Host "[ok] $t reiniciada."
  } else {
    Write-Host "[--] $t no existe en este nodo (se omite)."
  }
}
Write-Host "LISTO. Verifica C:\Supervisor\logs\webconfig_sync.log"
