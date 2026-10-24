Write-Host "== Programme (winget) ==" -ForegroundColor Cyan
winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements

Write-Host "== Microsoft Store Apps ==" -ForegroundColor Cyan
Get-CimInstance -Namespace "Root\cimv2\mdm\dmmap" -ClassName "MDM_EnterpriseModernAppManagement_AppManagement01" | Invoke-CimMethod -MethodName UpdateScanMethod

Write-Host "== Defender-Signaturen ==" -ForegroundColor Cyan
Update-MpSignature

Write-Host "== Windows Update ==" -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
    Install-Module PSWindowsUpdate -Force -Scope CurrentUser
}
Import-Module PSWindowsUpdate
Get-WindowsUpdate -MicrosoftUpdate -Install -AcceptAll -IgnoreReboot

Write-Host "Fertig! Ggf. neu starten." -ForegroundColor Green
Pause