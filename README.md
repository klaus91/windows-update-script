# Update-All.ps1

PowerShell-Script, das einen Windows-PC in einem Durchgang aktuell hält:

- **Microsoft Defender** – Virensignaturen
- **Windows Update** – inkl. Microsoft Update (Office, .NET, PowerShell 7 …), optional Treiber
- **Programme** – alle über `winget` installierbaren Anwendungen
- **Microsoft Store Apps** – stößt die Update-Suche an

Jeder Schritt meldet am Ende einen Status, alles wird in eine Logdatei geschrieben, und wenn Windows einen Neustart verlangt, wird angeboten, ihn direkt durchzuführen.

---

## Inhalt

- [Voraussetzungen](#voraussetzungen)
- [Installation](#installation)
- [Verwendung](#verwendung)
- [Parameter](#parameter)
- [Ablauf](#ablauf)
- [Status und Exitcode](#status-und-exitcode)
- [Logdateien](#logdateien)
- [Als geplante Aufgabe ausführen](#als-geplante-aufgabe-ausführen)
- [Pakete von winget ausnehmen](#pakete-von-winget-ausnehmen)
- [Fehlerbehebung](#fehlerbehebung)

---

## Voraussetzungen

| Komponente | Hinweis |
|---|---|
| Windows 10 / 11 | |
| Windows PowerShell 5.1 oder PowerShell 7 | Der Wiederherstellungspunkt funktioniert nur unter 5.1. |
| Administratorrechte | Das Script fordert sie bei Bedarf selbst per UAC an. |
| Internetzugang | Für Updates und für die einmalige Installation von PSWindowsUpdate. |
| winget (App Installer) | Optional – fehlt er, wird der Schritt übersprungen. |
| Microsoft Defender | Optional – ist er nicht aktiv (z. B. Fremd-Virenscanner), wird der Schritt übersprungen. |

Das Modul **PSWindowsUpdate** und der Paketanbieter **NuGet** werden beim ersten Lauf automatisch aus der PowerShell Gallery installiert (für alle Benutzer).

## Installation

1. `Update-All.ps1` in einen festen Ordner legen, z. B. `C:\Scripts\`.
2. Die Datei muss als **UTF-8 mit BOM** gespeichert sein, sonst zeigt Windows PowerShell 5.1 die Umlaute falsch an. In VS Code: unten rechts auf die Codierung klicken → *Mit Codierung speichern* → *UTF-8 with BOM*.
3. Falls die Datei aus dem Internet heruntergeladen wurde, die Sperre aufheben:
   ```powershell
   Unblock-File C:\Scripts\Update-All.ps1
   ```

## Verwendung

**Einfachster Aufruf** (aus einer beliebigen PowerShell oder per Verknüpfung):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Update-All.ps1"
```

Ohne Adminrechte gestartet, öffnet sich eine UAC-Abfrage und das Script startet sich in einem neuen, erhöhten Fenster neu. Alle angegebenen Parameter werden dabei übernommen.

**Beispiele:**

```powershell
# Mit Treibern und vorherigem Wiederherstellungspunkt
.\Update-All.ps1 -IncludeDrivers -CreateRestorePoint

# Auch winget-Pakete mit unbekannter Version aktualisieren
.\Update-All.ps1 -IncludeUnknown

# Ohne Abfrage am Ende, Logs nur 30 Tage aufbewahren
.\Update-All.ps1 -NoPause -LogRetentionDays 30
```

**Desktop-Verknüpfung:** Neue Verknüpfung anlegen und als Ziel eintragen:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Update-All.ps1"
```

## Parameter

| Parameter | Typ | Standard | Beschreibung |
|---|---|---|---|
| `-IncludeDrivers` | Switch | aus | Treiber-Updates über Windows Update mitinstallieren. |
| `-IncludeUnknown` | Switch | aus | winget-Pakete mit unbekannter Version einbeziehen. Kann dazu führen, dass dieselben Pakete bei jedem Lauf erneut „aktualisiert“ werden. |
| `-CreateRestorePoint` | Switch | aus | Vorher einen Wiederherstellungspunkt anlegen. Nur unter Windows PowerShell 5.1, die Systemwiederherstellung muss aktiviert sein. Windows erlaubt standardmäßig höchstens einen Punkt pro 24 Stunden. |
| `-NoPause` | Switch | aus | Am Ende nicht auf Enter warten und keinen Neustart anbieten (für geplante Aufgaben). |
| `-LogRetentionDays` | Zahl (1–3650) | 90 | Logs, die älter sind, werden beim Start gelöscht. |

## Ablauf

Die Schritte laufen in dieser Reihenfolge. Scheitert ein Schritt, wird er als *Fehler* markiert und das Script macht mit dem nächsten weiter.

1. **Wiederherstellungspunkt** *(nur mit `-CreateRestorePoint`)*
2. **Defender-Signaturen**
   - Bis zu 3 Versuche mit je 30 Sekunden Pause.
   - Schlägt der Befehl fehl, die Signaturen sind aber jünger als 24 Stunden, gilt der Schritt trotzdem als *OK*.
   - Läuft bewusst **vor** Windows Update, weil `Update-MpSignature` direkt nach einem Signatur-Update durch Windows Update oft mit „Der Remoteprozeduraufruf ist fehlgeschlagen“ scheitert.
3. **Windows Update** (über PSWindowsUpdate)
   - Sucht auch nach Microsoft-Update-Produkten (Office, .NET usw.).
   - Updates mit „Preview“ oder „Vorschau“ im Titel werden ausgelassen.
   - Treiber nur mit `-IncludeDrivers`.
   - Ein Neustart wird nicht automatisch ausgelöst.
4. **Programme (winget)**
   - Aktualisiert die Quellen und führt `winget upgrade --all` still aus.
   - Zeigt danach an, welche Pakete noch offen sind (fehlgeschlagen, gepinnt oder nicht automatisch aktualisierbar).
5. **Microsoft Store Apps**
   - Stößt über die MDM-Schnittstelle die Update-Suche des Stores an. Die eigentlichen Updates laufen danach im Hintergrund weiter, das Script wartet nicht darauf.
6. **Neustart-Prüfung und Zusammenfassung**
   - Prüft die Registrierungsschlüssel `RebootRequired` (Windows Update) und `RebootPending` (Component Based Servicing).
   - Gibt eine farbige Übersicht aller Schritte aus.
   - Bei ausstehendem Neustart wird gefragt: `Jetzt neu starten? (j/N)`. Der Neustart erfolgt ohne `-Force`, d. h. Programme mit ungespeicherten Daten können ihn noch aufhalten.

### Beispiel einer Zusammenfassung

```
== Zusammenfassung ==
Defender-Signaturen        OK – Version 1.421.1234.0 vom 18.11.2026 17:55
Windows Update             OK – 2 Update(s) installiert
Programme (winget)         Warnung – teilweise fehlgeschlagen (Exitcode 0x8A150011) – Liste oben prüfen
Microsoft Store Apps       OK – Scan angestoßen, Updates laufen im Hintergrund weiter

Neustart ausstehend – bitte neu starten, um die Updates abzuschließen.
```

## Status und Exitcode

| Status | Farbe | Bedeutung |
|---|---|---|
| OK | grün | Schritt erfolgreich (oder nichts zu tun). |
| Übersprungen | grau | Schritt nicht anwendbar, z. B. winget fehlt oder Defender nicht aktiv. |
| Warnung | gelb | Teilweise erfolgreich, z. B. einzelne Updates fehlgeschlagen. |
| Fehler | rot | Schritt ist abgebrochen. |

| Exitcode | Bedeutung |
|---|---|
| `0` | Alle Schritte *OK* oder *Übersprungen*. |
| `1` | Mindestens eine *Warnung* oder ein *Fehler*, ein unerwarteter Abbruch – oder die Adminrechte wurden verweigert. |

> **Hinweis:** Startet sich das Script per UAC selbst neu, beendet sich der ursprüngliche Prozess sofort mit `0`. Der echte Exitcode entsteht im neuen, erhöhten Prozess. Wer den Exitcode auswerten will (z. B. in einer geplanten Aufgabe), sollte das Script deshalb direkt mit Adminrechten starten.

## Logdateien

Die komplette Konsolenausgabe wird mitgeschrieben unter:

```
%ProgramData%\UpdateScript\Logs\Update_JJJJ-MM-TT_HH-mm-ss.log
```

also normalerweise `C:\ProgramData\UpdateScript\Logs\`. Der Pfad wird am Ende des Laufs angezeigt. Logs, die älter als `-LogRetentionDays` Tage sind (Standard 90), werden beim nächsten Start automatisch gelöscht. Kann kein Log angelegt werden, läuft das Script mit einer Warnung ohne Log weiter.

## Als geplante Aufgabe ausführen

Wichtig dabei:

- **„Mit höchsten Privilegien ausführen“** aktivieren – in einer geplanten Aufgabe kann keine UAC-Abfrage erscheinen.
- **`-NoPause`** angeben, sonst wartet das Script am Ende auf eine Eingabe.
- Unter einem **normalen Benutzerkonto** (mit Adminrechten) ausführen, nicht als `SYSTEM`: winget ist pro Benutzer installiert und für das SYSTEM-Konto in der Regel nicht auffindbar – der winget-Schritt würde dann übersprungen.

Einrichtung per PowerShell (als Administrator), z. B. jeden Sonntag um 12:00 Uhr:

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
           -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Update-All.ps1" -NoPause'
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 12:00
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3)

Register-ScheduledTask -TaskName 'Update-All' -Action $action -Trigger $trigger `
    -Settings $settings -RunLevel Highest -User $env:USERNAME
```

Mit `-NoPause` wird kein Neustart durchgeführt; ein ausstehender Neustart steht nur in der Zusammenfassung bzw. im Log.

## Pakete von winget ausnehmen

Manche Programme aktualisieren sich selbst oder lassen sich mit Adminrechten nicht installieren und erzeugen dann bei jedem Lauf eine Warnung. Diese einmalig per Pin von `winget upgrade --all` ausnehmen:

```powershell
winget pin add --id Spotify.Spotify
winget pin add --id Microsoft.Edge
winget pin add --id Logitech.GHUB
winget pin add --id Ubisoft.Connect
```

Pins anzeigen bzw. wieder entfernen:

```powershell
winget pin list
winget pin remove --id Spotify.Spotify
```

## Fehlerbehebung

| Problem | Lösung |
|---|---|
| Umlaute werden als `Ã¤` o. Ä. angezeigt | Datei als **UTF-8 mit BOM** speichern. |
| „Die Ausführung von Skripts ist auf diesem System deaktiviert“ | Mit `-ExecutionPolicy Bypass` starten (siehe [Verwendung](#verwendung)) oder `Unblock-File` ausführen. |
| Fenster schließt sich sofort | Über eine Verknüpfung mit dem vollständigen `powershell.exe …`-Aufruf starten, nicht per Doppelklick auf die `.ps1`. |
| „Adminrechte wurden nicht erteilt – Abbruch.“ | UAC-Abfrage wurde abgelehnt – erneut starten und bestätigen. |
| Windows Update: Fehler bei der Installation von PSWindowsUpdate | Internetverbindung prüfen; ggf. einmal manuell `Install-Module PSWindowsUpdate -Scope AllUsers` ausführen. |
| Wiederherstellungspunkt *Übersprungen* | Script läuft unter PowerShell 7 – mit `powershell.exe` (5.1) statt `pwsh.exe` starten. |
| Wiederherstellungspunkt *Fehler* | Systemwiederherstellung für Laufwerk C: aktivieren (`sysdm.cpl` → Computerschutz). |
| winget *Warnung* | In der Liste „Nach dem Lauf noch offen“ nachsehen, welches Paket hängt, und es ggf. pinnen (siehe oben). |
| winget immer wieder dieselben „Updates“ | `-IncludeUnknown` weglassen. |
