#Requires -Version 5.1
<#
.SYNOPSIS
    Aktualisiert Programme (winget), Store-Apps, Defender-Signaturen und Windows Updates.

.DESCRIPTION
    Jeder Schritt meldet einen Status: OK, Warnung, Übersprungen oder Fehler.
    Exitcode: 0 = alles OK oder übersprungen, 1 = mindestens eine Warnung oder ein Fehler.

.PARAMETER IncludeDrivers
    Treiber-Updates über Windows Update mitinstallieren (Standard: aus).

.PARAMETER IncludeUnknown
    winget-Pakete mit unbekannter Version einbeziehen (kann zu Dauer-"Updates" führen).

.PARAMETER CreateRestorePoint
    Vorher einen Wiederherstellungspunkt anlegen (nur Windows PowerShell 5.1,
    Systemwiederherstellung muss aktiv sein; standardmäßig max. 1 Punkt pro 24 h).

.PARAMETER NoPause
    Am Ende nicht auf Enter warten und keinen Neustart anbieten (für geplante Aufgaben).

.PARAMETER LogRetentionDays
    Logs, die älter als diese Anzahl Tage sind, werden beim Start gelöscht (Standard: 90).

.NOTES
    Datei als UTF-8 MIT BOM speichern, sonst zeigt Windows PowerShell 5.1 Umlaute falsch an.

    Pakete, die sich selbst aktualisieren oder mit Adminrechten nicht installierbar sind,
    einmalig von "winget upgrade --all" ausnehmen, z. B.:
        winget pin add --id Spotify.Spotify
        winget pin add --id Microsoft.Edge
        winget pin add --id Logitech.GHUB
        winget pin add --id Ubisoft.Connect
#>
[CmdletBinding()]
param(
    [switch]$IncludeDrivers,
    [switch]$IncludeUnknown,
    [switch]$CreateRestorePoint,
    [switch]$NoPause,
    [ValidateRange(1, 3650)][int]$LogRetentionDays = 90
)

# --- Selbst-Erhöhung: startet sich mit Adminrechten neu (UAC-Abfrage) -------
# Bewusst keine Requires-Anweisung für Adminrechte: Die würde das Fenster beim
# Start über eine Verknüpfung ohne Adminrechte sofort kommentarlos schließen.
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($param in $PSBoundParameters.GetEnumerator()) {
        if ($param.Value -is [switch]) {
            if ($param.Value) { $argList += "-$($param.Key)" }   # nur gesetzte Switches
        }
        else {
            $argList += "-$($param.Key)", "$($param.Value)"      # z. B. -LogRetentionDays 30
        }
    }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList
        exit 0
    }
    catch {
        Write-Host 'Adminrechte wurden nicht erteilt - Abbruch.' -ForegroundColor Red
        if (-not $NoPause -and [Environment]::UserInteractive) {
            Read-Host 'Enter zum Beenden' | Out-Null
        }
        exit 1
    }
}

$ErrorActionPreference = 'Stop'

# --- Hilfsfunktionen ---------------------------------------------------------
$results = [ordered]@{}

function Set-StepResult {
    param(
        [Parameter(Mandatory)][ValidateSet('OK', 'Warnung', 'Übersprungen', 'Fehler')][string]$Status,
        [string]$Note
    )
    $script:StepStatus = $Status
    $script:StepNote   = $Note
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    Write-Host "`n== $Name ==" -ForegroundColor Cyan
    $script:StepStatus = 'OK'
    $script:StepNote   = $null
    try {
        & $Action
    }
    catch {
        Write-Warning "$Name fehlgeschlagen: $($_.Exception.Message)"
        $script:StepStatus = 'Fehler'
        $script:StepNote   = $_.Exception.Message
    }
    $results[$Name] = [pscustomobject]@{ Status = $script:StepStatus; Note = $script:StepNote }
}

# --- Logging -----------------------------------------------------------------
$logFile           = $null
$transcriptStarted = $false
try {
    $logDir  = Join-Path $env:ProgramData 'UpdateScript\Logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $logFile = Join-Path $logDir ('Update_{0:yyyy-MM-dd_HH-mm-ss}.log' -f (Get-Date))
    Start-Transcript -Path $logFile | Out-Null
    $transcriptStarted = $true
}
catch {
    Write-Warning "Protokollierung nicht möglich, es wird ohne Log fortgefahren: $($_.Exception.Message)"
}

# --- Alte Logs aufräumen -----------------------------------------------------
if ($transcriptStarted) {
    try {
        $cutoff  = (Get-Date).AddDays(-$LogRetentionDays)
        $oldLogs = @(Get-ChildItem -Path (Split-Path $logFile) -Filter 'Update_*.log' -File |
                     Where-Object { $_.LastWriteTime -lt $cutoff })
        if ($oldLogs.Count -gt 0) {
            $oldLogs | Remove-Item -Force
            Write-Host ('{0} Log(s) älter als {1} Tage gelöscht.' -f $oldLogs.Count, $LogRetentionDays)
        }
    }
    catch {
        Write-Warning "Alte Logs konnten nicht gelöscht werden: $($_.Exception.Message)"
    }
}

$fatalError   = $false
$rebootNeeded = $false
try {
    # --- Wiederherstellungspunkt (optional) ----------------------------------
    if ($CreateRestorePoint) {
        Invoke-Step 'Wiederherstellungspunkt' {
            if (-not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)) {
                Set-StepResult 'Übersprungen' 'nur in Windows PowerShell 5.1 verfügbar'
                return
            }
            Checkpoint-Computer -Description 'Vor Update-Script' -RestorePointType MODIFY_SETTINGS
        }
    }

    # --- Defender-Signaturen -------------------------------------------------
    # Bewusst VOR Windows Update: Installiert Windows Update gerade selbst ein
    # Signatur-Update, scheitert Update-MpSignature direkt danach oft mit
    # "Der Remoteprozeduraufruf ist fehlgeschlagen".
    Invoke-Step 'Defender-Signaturen' {
        $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if (-not $mp -or -not $mp.AMServiceEnabled) {
            Set-StepResult 'Übersprungen' 'Microsoft Defender ist nicht aktiv'
            return
        }

        $lastError = $null
        for ($try = 1; $try -le 3; $try++) {
            try {
                Update-MpSignature
                $lastError = $null
                break
            }
            catch {
                $lastError = $_.Exception.Message
                if ($try -lt 3) {
                    Write-Host "Versuch $try fehlgeschlagen ($lastError) - neuer Versuch in 30 s ..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 30
                }
            }
        }

        $mp    = Get-MpComputerStatus
        $stand = 'Version {0} vom {1:dd.MM.yyyy HH:mm}' -f $mp.AntivirusSignatureVersion, $mp.AntivirusSignatureLastUpdated

        if (-not $lastError) {
            Set-StepResult 'OK' $stand
        }
        elseif ($mp.AntivirusSignatureLastUpdated -gt (Get-Date).AddHours(-24)) {
            # Update-Befehl gescheitert, die Signaturen sind aber trotzdem aktuell
            Set-StepResult 'OK' "$stand (Update-Befehl gescheitert, Signaturen aber aktuell)"
        }
        else {
            throw $lastError
        }
    }

    # --- Windows Update ------------------------------------------------------
    Invoke-Step 'Windows Update' {
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            # Ältere 5.1-Installationen sprechen sonst kein TLS 1.2 mit der PowerShell Gallery
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

            # Fehlt NuGet oder ist die Version zu alt, wird er (neu) installiert
            if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
                      Where-Object Version -ge '2.8.5.201')) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope AllUsers -Force | Out-Null
            }
            # AllUsers statt CurrentUser: landet nicht im (evtl. OneDrive-synchronisierten) Admin-Profil
            Install-Module -Name PSWindowsUpdate -Repository PSGallery -Scope AllUsers -Force
        }
        Import-Module PSWindowsUpdate
        Write-Host ('PSWindowsUpdate-Version: {0}' -f (Get-Module PSWindowsUpdate).Version)

        $wuParams = @{
            MicrosoftUpdate = $true               # auch Office, .NET, PowerShell 7 usw.
            Install         = $true
            AcceptAll       = $true
            IgnoreReboot    = $true
            NotTitle        = 'Preview|Vorschau'  # regulärer Ausdruck (PSWindowsUpdate filtert mit -match)
        }
        if (-not $IncludeDrivers) { $wuParams.UpdateType = 'Software' }

        # Tee-Object: Ausgabe sofort anzeigen und zugleich für die Auswertung merken
        Get-WindowsUpdate @wuParams | Tee-Object -Variable wuOutput | Out-Host

        $wuItems    = @($wuOutput | Where-Object { $null -ne $_ })
        $withResult = @($wuItems  | Where-Object { $_.PSObject.Properties['Result'] })
        $failed     = @($withResult | Where-Object { $_.Result -match 'Failed' } |
                        ForEach-Object { $_.Title } | Select-Object -Unique)
        $installed  = @($withResult | Where-Object { $_.Result -match 'Installed' } |
                        ForEach-Object { $_.Title } | Select-Object -Unique)

        if ($failed.Count -gt 0) {
            Set-StepResult 'Warnung' ('{0} Update(s) fehlgeschlagen: {1}' -f $failed.Count, ($failed -join '; '))
        }
        elseif ($installed.Count -gt 0) {
            Set-StepResult 'OK' ('{0} Update(s) installiert' -f $installed.Count)
        }
        elseif ($wuItems.Count -eq 0) {
            Set-StepResult 'OK' 'keine Updates gefunden'
        }
        else {
            Set-StepResult 'OK' 'Ergebnis siehe Ausgabe oben'
        }
    }


    # --- Programme (winget) --------------------------------------------------
    Invoke-Step 'Programme (winget)' {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Set-StepResult 'Übersprungen' 'winget nicht gefunden (App Installer fehlt)'
            return
        }
        winget source update --disable-interactivity | Out-Null
        $sourceExit = $LASTEXITCODE

        $wingetArgs = @(
            'upgrade', '--all',
            '--silent', '--disable-interactivity',
            '--accept-package-agreements', '--accept-source-agreements'
        )
        if ($IncludeUnknown) { $wingetArgs += '--include-unknown' }

        winget @wingetArgs
        $wingetExit = $LASTEXITCODE

        # Kontrolle: Was ist nach dem Lauf noch offen (fehlgeschlagene oder blockierte Pakete)?
        # Nur zur Information; "| Out-Host" sorgt dafür, dass die Liste auch im Log landet.
        Write-Host "`nNach dem Lauf noch offen:" -ForegroundColor Cyan
        # Weitergeleitet liefert winget UTF-8; ohne Umstellung zeigt PowerShell 5.1
        # Umlaute als "├╝" an. Danach wird die ursprüngliche Codierung wiederhergestellt.
        $prevEncoding = [Console]::OutputEncoding
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
        # --include-unknown auch hier, sonst fehlen diese Pakete in der Kontrollliste
        $listArgs = @('upgrade', '--disable-interactivity', '--accept-source-agreements')
        if ($IncludeUnknown) { $listArgs += '--include-unknown' }
        try {
            winget @listArgs | Out-Host
        }
        finally {
            try { [Console]::OutputEncoding = $prevEncoding } catch { }
        }

        # 0x8A15002B (-1978335189) = APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE:
        # "kein anwendbares Update gefunden" - also nichts zu tun, kein Fehler.
        if ($wingetExit -eq -1978335189) {
            Set-StepResult 'OK' 'keine Updates gefunden'
        }
        elseif ($wingetExit -ne 0) {
            Set-StepResult 'Warnung' ('teilweise fehlgeschlagen (Exitcode 0x{0:X8}) - Liste oben prüfen' -f $wingetExit)
        }
        elseif ($sourceExit -ne 0) {
            Set-StepResult 'Warnung' ('Quellen-Aktualisierung fehlgeschlagen (Exitcode 0x{0:X8}) - evtl. nicht alle Updates erkannt' -f $sourceExit)
        }
    }

    # --- Microsoft Store Apps ------------------------------------------------
    Invoke-Step 'Microsoft Store Apps' {
        $r = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' `
                             -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' |
             Invoke-CimMethod -MethodName UpdateScanMethod
        if ($r.ReturnValue -ne 0) { throw "UpdateScanMethod lieferte ReturnValue $($r.ReturnValue)" }
        Set-StepResult 'OK' 'Scan angestoßen, Updates laufen im Hintergrund weiter'
    }

    # --- Neustart ausstehend? ------------------------------------------------
    $rebootKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )
    $rebootNeeded = [bool]($rebootKeys | Where-Object { Test-Path $_ })

    # --- Zusammenfassung -----------------------------------------------------
    $colors = @{ 'OK' = 'Green'; 'Übersprungen' = 'Gray'; 'Warnung' = 'Yellow'; 'Fehler' = 'Red' }

    Write-Host "`n== Zusammenfassung ==" -ForegroundColor Cyan
    foreach ($name in $results.Keys) {
        $r    = $results[$name]
        $text = if ($r.Note) { '{0} - {1}' -f $r.Status, $r.Note } else { $r.Status }
        Write-Host ('{0,-26} {1}' -f $name, $text) -ForegroundColor $colors[$r.Status]
    }

    if ($rebootNeeded) {
        Write-Host "`nNeustart ausstehend - bitte neu starten, um die Updates abzuschließen." -ForegroundColor Yellow
    } else {
        Write-Host "`nKein Neustart-Hinweis von Windows Update gefunden." -ForegroundColor Green
    }
}
catch {
    $fatalError = $true
    Write-Host "`nUnerwarteter Fehler: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($logFile -and $transcriptStarted) { Write-Host "Log: $logFile" }
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

$interactive = -not $NoPause -and [Environment]::UserInteractive

if ($interactive -and $rebootNeeded) {
    Write-Host "`nOffene Programme werden beim Neustart geschlossen - vorher alles speichern." -ForegroundColor Yellow
    $answer = Read-Host 'Jetzt neu starten? (j/N)'
    if ($answer -match '^\s*(j|ja|y|yes)\s*$') {
        try {
            # Ohne -Force: Programme mit ungespeicherten Daten können den Neustart
            # noch aufhalten, wie beim Neustart über das Startmenü.
            Restart-Computer
        }
        catch {
            Write-Host "Neustart nicht möglich: $($_.Exception.Message)" -ForegroundColor Red
            Read-Host 'Enter zum Beenden' | Out-Null
        }
    }
}
elseif ($interactive) {
    Read-Host 'Enter zum Beenden' | Out-Null
}

$problems = @($results.Values | Where-Object { $_.Status -in 'Warnung', 'Fehler' })
exit $(if ($fatalError -or $problems.Count -gt 0) { 1 } else { 0 })