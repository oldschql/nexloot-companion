# NexLoot Companion - kleines Programm im Infobereich (Tray) fuer Offiziere / Lootmaster.
# Liest die NexLoot-Daten aus WoW (SavedVariables), laedt sie in die Webapp-Datenbank (Supabase)
# und schreibt neuere Staende aus der Webapp als WebData.lua in den NexLoot-Addon-Ordner.
# Start: "NexLoot Companion.bat" (oder: powershell -ExecutionPolicy Bypass -File NexLootCompanion.ps1)
param(
    [switch] $Setup,      # Einstellungen oeffnen
    [switch] $NoUi,       # nur Funktionen laden (Tests)
    [string] $DataDir = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # sonst ist Invoke-WebRequest in Windows PowerShell 5.1 sehr langsam
. (Join-Path $PSScriptRoot 'NexLootCore.ps1')

$script:AppVersion = '1.6.2'
if (-not $DataDir) { $DataDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'NexLootCompanion' }
$script:DataDir = $DataDir
$script:ConfigPath = Join-Path $DataDir 'config.json'
$script:StatePath = Join-Path $DataDir 'state.json'
$script:LogPath = Join-Path $DataDir 'protokoll.txt'
if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

# ---------------------------------------------------------------------------------------------
# Protokoll, Einstellungen, Zustand
# ---------------------------------------------------------------------------------------------
function Write-NexLog([string] $Msg) {
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 512KB) {
            $old = $script:LogPath + '.alt'
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
            Move-Item -LiteralPath $script:LogPath $old
        }
        [System.IO.File]::AppendAllText($script:LogPath, [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Msg + "`r`n", $script:NexUtf8)
    } catch { }
}

# Passwort mit Windows-Verschluesselung (DPAPI) speichern: nur dieser Windows-Benutzer kann es lesen
function Protect-NexSecret([string] $Plain) {
    if (-not $Plain) { return '' }
    try { return 'dpapi:' + (ConvertTo-SecureString -String $Plain -AsPlainText -Force | ConvertFrom-SecureString) }
    catch { return 'plain:' + $Plain }
}
function Unprotect-NexSecret([string] $Stored) {
    if (-not $Stored) { return '' }
    if ($Stored.StartsWith('dpapi:')) {
        $ss = ConvertTo-SecureString -String $Stored.Substring(6)
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    }
    if ($Stored.StartsWith('plain:')) { return $Stored.Substring(6) }
    return $Stored
}

function Read-NexConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return $null }
    try { return ConvertFrom-NexJson ([System.IO.File]::ReadAllText($script:ConfigPath, $script:NexUtf8)) } catch { return $null }
}
function Save-NexConfig($Raw) { Write-NexFileAtomic $script:ConfigPath (ConvertTo-NexJson $Raw) }

function Get-NexCfg($Raw) {
    return [pscustomobject]@{
        url = [string]$Raw['url']; key = [string]$Raw['key']; guild = [string]$Raw['guild']
        password = (Unprotect-NexSecret ([string]$Raw['password'])); name = [string]$Raw['name']
        svPath = [string]$Raw['svPath']; addonPath = [string]$Raw['addonPath']; webUrl = [string]$Raw['webUrl']
        discordUrl = (Unprotect-NexSecret ([string]$Raw['discord'])); discordSince = (Get-NexLong $Raw['discordSince'])
    }
}

# Sicherung per Mail (1.6): eigene Einstellungen, nur auf diesem PC (nicht im Verbindungscode)
function Get-NexMailCfg($Raw) {
    if ($null -eq $Raw) { return $null }
    $hostName = [string]$Raw['mailHost']; if (-not $hostName) { $hostName = 'smtp.gmail.com' }
    $port = Get-NexLong $Raw['mailPort'] 587; if ($port -le 0) { $port = 587 }
    $hour = 22; if ($Raw.Contains('mailHour')) { $hour = [int](Get-NexLong $Raw['mailHour'] 22) }
    $from = ([string]$Raw['mailFrom']).Trim()
    return [pscustomobject]@{
        on = [bool]$Raw['mailOn']; to = ([string]$Raw['mailTo']).Trim(); from = $from; user = $from
        pass = (Unprotect-NexSecret ([string]$Raw['mailPass'])); host = $hostName; port = [int]$port; ssl = $true; hour = $hour
    }
}

function Read-NexState {
    $st = $null
    if (Test-Path -LiteralPath $script:StatePath) { try { $st = ConvertFrom-NexJson ([System.IO.File]::ReadAllText($script:StatePath, $script:NexUtf8)) } catch { } }
    if (-not ($st -is [System.Collections.IDictionary])) { $st = New-Object System.Collections.Specialized.OrderedDictionary }
    return $st
}
function Save-NexState($St) { Write-NexFileAtomic $script:StatePath (ConvertTo-NexJson $St) }

# Verbindungscode: alles, was ein weiterer Offizier braucht, in einer Zeile (enthaelt das Schreib-Passwort!)
function New-NexConnectionCode($Raw) {
    $o = [ordered]@{ u = [string]$Raw['url']; k = [string]$Raw['key']; g = [string]$Raw['guild']; p = (Unprotect-NexSecret ([string]$Raw['password'])); w = [string]$Raw['webUrl'] }
    return 'NEXLOOT1:' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-NexJson $o)))
}
function Read-NexConnectionCode([string] $Code) {
    $Code = $Code.Trim()
    if (-not $Code.StartsWith('NEXLOOT1:')) { return $null }
    try {
        $j = ConvertFrom-NexJson ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Code.Substring(9))))
        if ($j -is [System.Collections.IDictionary] -and $j['u'] -and $j['k'] -and $j['g']) { return $j }
    } catch { }
    return $null
}

# ---------------------------------------------------------------------------------------------
# WoW-Ordner finden: ...\World of Warcraft\_classic_beta_\WTF\Account\<Konto>\SavedVariables\NexLoot.lua
# ---------------------------------------------------------------------------------------------
function Find-NexWowCandidates([string[]] $Roots = @()) {
    $list = New-Object System.Collections.ArrayList
    $rootList = New-Object System.Collections.ArrayList
    $given = @($Roots | Where-Object { $_ })
    foreach ($r in $given) { [void]$rootList.Add($r) }
    if ($given.Count -eq 0) {
        $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        foreach ($r in @($pf86, $env:ProgramFiles, $env:ProgramW6432)) { if ($r) { [void]$rootList.Add((Join-Path $r 'World of Warcraft')) } }
        try {
            foreach ($key in @('HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft', 'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft')) {
                $ip = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).InstallPath
                if ($ip) { [void]$rootList.Add($ip); [void]$rootList.Add((Split-Path ($ip.TrimEnd('\')) -Parent)) }
            }
        } catch { }
        try {
            foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
                if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
                foreach ($sub in @('World of Warcraft', 'Games\World of Warcraft', 'Program Files (x86)\World of Warcraft', 'Program Files\World of Warcraft', 'Blizzard\World of Warcraft', 'Battle.net\World of Warcraft')) {
                    [void]$rootList.Add((Join-Path $d.RootDirectory.FullName $sub))
                }
            }
        } catch { }
    }
    $seen = @{}
    foreach ($root in $rootList) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $flavors = @()
        if (Test-Path -LiteralPath (Join-Path $root 'WTF')) { $flavors += Get-Item -LiteralPath $root }
        $flavors += @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '_*_' })
        foreach ($f in $flavors) {
            $acctRoot = Join-Path $f.FullName 'WTF\Account'
            $addon = Join-Path $f.FullName 'Interface\AddOns\NexLoot'
            if (-not (Test-Path -LiteralPath $acctRoot)) { continue }
            foreach ($a in (Get-ChildItem -LiteralPath $acctRoot -Directory -ErrorAction SilentlyContinue)) {
                if ($a.Name -eq 'SavedVariables') { continue }
                $sv = Join-Path $a.FullName 'SavedVariables\NexLoot.lua'
                $key = $sv.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $has = Test-Path -LiteralPath $sv
                if (-not $has -and -not (Test-Path -LiteralPath $addon)) { continue }
                $when = 0
                if ($has) { $when = (Get-Item -LiteralPath $sv).LastWriteTimeUtc.Ticks }
                $label = $f.Name + '  -  Konto ' + $a.Name
                if (-not $has) { $label += '  (noch keine NexLoot-Daten)' }
                if (-not (Test-Path -LiteralPath $addon)) { $label += '  (NexLoot-Addon fehlt!)' }
                [void]$list.Add([pscustomobject]@{ Label = $label; Sv = $sv; Addon = $addon; When = $when })
            }
        }
    }
    $sorted = New-Object System.Collections.ArrayList
    foreach ($c in ($list | Sort-Object -Property When -Descending)) { [void]$sorted.Add($c) }
    return , $sorted
}

# ---------------------------------------------------------------------------------------------
# Autostart (Verknuepfung im Autostart-Ordner)
# ---------------------------------------------------------------------------------------------
function Get-NexAutostartPath { return Join-Path ([Environment]::GetFolderPath('Startup')) 'NexLoot Companion.lnk' }
function Test-NexAutostart { return (Test-Path -LiteralPath (Get-NexAutostartPath)) }
# 1.6.2: ueber conhost.exe --headless starten - sonst zeigt Windows 11 (Windows-Terminal) ein Fenster in der Taskleiste
function Get-NexLaunch([string] $Extra = '') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $ch = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $PSScriptRoot 'NexLootCompanion.ps1') + '"'
    if ($Extra) { $argLine += ' ' + $Extra }
    if (Test-Path -LiteralPath $ch) { return [pscustomobject]@{ File = $ch; Args = '--headless "' + $ps + '" ' + $argLine } }
    return [pscustomobject]@{ File = $ps; Args = $argLine }
}
function Set-NexAutostart([bool] $On) {
    $lnk = Get-NexAutostartPath
    if (-not $On) { if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }; return }
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $l = Get-NexLaunch
    $s.TargetPath = $l.File
    $s.Arguments = $l.Args
    $s.WorkingDirectory = $PSScriptRoot
    $s.WindowStyle = 7
    $s.Description = 'NexLoot Companion'
    $s.Save()
}

# ---------------------------------------------------------------------------------------------
# Oberflaeche
# ---------------------------------------------------------------------------------------------
function New-NexIcon([System.Drawing.Color] $Ring) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $Ring), 0, 0, 32, 32)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 24, 22, 32))), 3, 3, 26, 26)
    $font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('N', $font, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 209, 0))), (New-Object System.Drawing.RectangleF(0, 1, 32, 32)), $fmt)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Show-NexSetup($Raw) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'NexLoot Companion - Einrichtung'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object System.Drawing.Size(600, 640)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $f.Icon = New-NexIcon ([System.Drawing.Color]::FromArgb(255, 255, 209, 0))
    $f.TopMost = $true
    $y = 14
    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = "Einmal einrichten. Am einfachsten: den Verbindungscode einfügen, den du vom Gildenleiter bekommst – " +
        "dann sind die oberen Felder schon ausgefüllt. Danach nur noch deinen Namen und den WoW-Ordner prüfen."
    $intro.SetBounds(14, $y, 572, 36); $f.Controls.Add($intro); $y += 44
    $fields = @{}
    $add = {
        param($label, $name, $secret)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $label; $l.SetBounds(14, $script:sy + 3, 170, 20); $f.Controls.Add($l)
        $t = New-Object System.Windows.Forms.TextBox
        $t.SetBounds(186, $script:sy, 400, 24)
        if ($secret) { $t.UseSystemPasswordChar = $true }
        $f.Controls.Add($t)
        $fields[$name] = $t
        $script:sy += 32
    }
    $script:sy = $y
    & $add 'Verbindungscode:' 'code' $false
    $script:sy += 6
    & $add 'Supabase-Adresse:' 'url' $false
    & $add 'Öffentlicher Schlüssel:' 'key' $false
    & $add 'Gilde (Kennung):' 'guild' $false
    & $add 'Schreib-Passwort:' 'password' $true
    & $add 'Dein Charaktername:' 'name' $false
    & $add 'Webapp-Adresse (optional):' 'webUrl' $false
    & $add 'Discord-Webhook (optional):' 'discord' $true
    $dhint = New-Object System.Windows.Forms.Label
    $dhint.Text = 'Nach jedem Raid eine Zusammenfassung in einen Discord-Kanal (Webhook: Kanal → Einstellungen → Integrationen). Geheim halten!'
    $dhint.SetBounds(186, $script:sy - 6, 400, 30); $dhint.ForeColor = [System.Drawing.Color]::FromArgb(255, 90, 90, 90); $f.Controls.Add($dhint)
    $script:sy += 28
    $y = $script:sy + 6
    $lw = New-Object System.Windows.Forms.Label
    $lw.Text = 'WoW (Konto mit NexLoot):'; $lw.SetBounds(14, $y + 3, 170, 20); $f.Controls.Add($lw)
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'; $combo.SetBounds(186, $y, 400, 24); $f.Controls.Add($combo)
    $y += 30
    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = 'WoW-Ordner selbst wählen …'; $browse.SetBounds(186, $y, 200, 26); $f.Controls.Add($browse)
    $y += 34
    $auto = New-Object System.Windows.Forms.CheckBox
    $auto.Text = 'Mit Windows starten (empfohlen)'; $auto.SetBounds(186, $y, 300, 22); $auto.Checked = $true; $f.Controls.Add($auto)
    $y += 30
    $status = New-Object System.Windows.Forms.Label
    $status.SetBounds(14, $y, 572, 54); $status.ForeColor = [System.Drawing.Color]::FromArgb(255, 60, 60, 60); $f.Controls.Add($status)
    $test = New-Object System.Windows.Forms.Button
    $test.Text = 'Verbindung testen'; $test.SetBounds(14, 592, 150, 30); $f.Controls.Add($test)
    $dtest = New-Object System.Windows.Forms.Button
    $dtest.Text = 'Discord testen'; $dtest.SetBounds(170, 592, 120, 30); $f.Controls.Add($dtest)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Speichern'; $ok.SetBounds(386, 592, 96, 30); $f.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Abbrechen'; $cancel.SetBounds(490, 592, 96, 30); $f.Controls.Add($cancel)
    $f.AcceptButton = $ok; $f.CancelButton = $cancel

    $script:cands = Find-NexWowCandidates
    $fill = {
        $combo.Items.Clear()
        foreach ($c in $script:cands) { [void]$combo.Items.Add($c.Label) }
        if ($combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }
    }
    & $fill
    if ($null -ne $Raw) {
        foreach ($k in @('url', 'key', 'guild', 'name', 'webUrl')) { if ($Raw.Contains($k)) { $fields[$k].Text = [string]$Raw[$k] } }
        if ($Raw.Contains('password')) { $fields['password'].Text = Unprotect-NexSecret ([string]$Raw['password']) }
        if ($Raw.Contains('discord')) { $fields['discord'].Text = Unprotect-NexSecret ([string]$Raw['discord']) }
        if ($Raw['svPath']) {
            $idx = -1
            for ($i = 0; $i -lt $script:cands.Count; $i++) { if ($script:cands[$i].Sv -eq $Raw['svPath']) { $idx = $i } }
            if ($idx -lt 0) {
                [void]$script:cands.Insert(0, [pscustomobject]@{ Label = [string]$Raw['svPath']; Sv = [string]$Raw['svPath']; Addon = [string]$Raw['addonPath']; When = 0 })
                & $fill
                $idx = 0
            }
            $combo.SelectedIndex = $idx
        }
        $auto.Checked = Test-NexAutostart
    }
    if (-not $fields['name'].Text) { $fields['name'].Text = $env:USERNAME }
    if ($script:cands.Count -eq 0) { $status.Text = 'Kein WoW-Ordner mit NexLoot gefunden – bitte „WoW-Ordner selbst wählen“.' }

    $fields['code'].Add_TextChanged({
        $j = Read-NexConnectionCode $fields['code'].Text
        if ($null -ne $j) {
            $fields['url'].Text = [string]$j['u']; $fields['key'].Text = [string]$j['k']; $fields['guild'].Text = [string]$j['g']
            if ($j['p']) { $fields['password'].Text = [string]$j['p'] }
            if ($j['w']) { $fields['webUrl'].Text = [string]$j['w'] }
            $status.Text = 'Verbindungscode übernommen.'
        }
    })
    $browse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Ordner „World of Warcraft“ bzw. „_classic_beta_“ wählen'
        if ($dlg.ShowDialog($f) -eq 'OK') {
            $found = Find-NexWowCandidates @($dlg.SelectedPath, (Split-Path $dlg.SelectedPath -Parent))
            if ($found.Count -eq 0) { $status.Text = 'Dort gibt es kein WTF\Account mit NexLoot. Bitte den Ordner wählen, in dem „WTF“ und „Interface“ liegen.' }
            else { foreach ($c in $found) { [void]$script:cands.Insert(0, $c) }; & $fill; $status.Text = 'Gefunden: ' + $found[0].Label }
        }
    })
    $collect = {
        $r = New-Object System.Collections.Specialized.OrderedDictionary
        $r['url'] = $fields['url'].Text.Trim().TrimEnd('/')
        $r['key'] = $fields['key'].Text.Trim()
        $r['guild'] = $fields['guild'].Text.Trim()
        $r['password'] = Protect-NexSecret $fields['password'].Text
        $r['name'] = $fields['name'].Text.Trim()
        $r['webUrl'] = $fields['webUrl'].Text.Trim()
        $dh = $fields['discord'].Text.Trim()
        $r['discord'] = Protect-NexSecret $dh
        # ab wann posten: ab jetzt (neuer/anderer Webhook) - aeltere Raids werden nicht nachgeholt
        $oldHook = ''; if ($null -ne $Raw -and $Raw.Contains('discord')) { $oldHook = Unprotect-NexSecret ([string]$Raw['discord']) }
        if ($dh -and $dh -eq $oldHook -and $Raw.Contains('discordSince')) { $r['discordSince'] = Get-NexLong $Raw['discordSince'] }
        elseif ($dh) { $r['discordSince'] = Get-NexUnixNow }
        if ($combo.SelectedIndex -ge 0) { $c = $script:cands[$combo.SelectedIndex]; $r['svPath'] = $c.Sv; $r['addonPath'] = $c.Addon }
        if ($null -ne $Raw) { foreach ($k in @($Raw.Keys)) { if (([string]$k).StartsWith('mail')) { $r[$k] = $Raw[$k] } } } # Sicherung per Mail bleibt
        return $r
    }
    $test.Add_Click({
        $r = & $collect
        $status.Text = 'Teste …'; $f.Refresh()
        try {
            $cfg = Get-NexCfg $r
            $w = Get-NexWeb $cfg
            [void](Invoke-NexHttp $cfg 'POST' '/rest/v1/rpc/nexloot_auth' ([ordered]@{ p_guild = $cfg.guild; p_secret = $cfg.password }))
            if ($null -eq $w) { $status.Text = 'Verbindung ok, Passwort ok. In der Webapp sind noch keine Daten – die kommen beim ersten Abgleich.' }
            else { $status.Text = 'Verbindung ok, Passwort ok. Webapp-Stand: ' + $w['rev'] + ' (' + $w['coins'].Count + ' Spieler, ' + $w['history'].Count + ' vergebene Items).' }
        } catch { $status.Text = 'Fehler: ' + $_.Exception.Message }
    })
    $dtest.Add_Click({
        $u = $fields['discord'].Text.Trim()
        if (-not (Test-NexWebhookUrl $u)) { $status.Text = 'Discord: bitte die Webhook-Adresse aus Discord einfügen (https://discord.com/api/webhooks/…).'; return }
        $status.Text = 'Discord: sende Test …'; $f.Refresh()
        $p = [ordered]@{ username = 'NexLoot'; content = 'NexLoot Companion: Test – der Webhook funktioniert. Nach jedem Raid kommt hier die Zusammenfassung.'
            allowed_mentions = [ordered]@{ parse = (New-Object System.Collections.ArrayList) } }
        $res = Send-NexDiscord $u $p
        if ($res.Ok) { $status.Text = 'Discord: Testnachricht gesendet – schau in den Kanal.' } else { $status.Text = $res.Message }
    })
    $script:setupResult = $null
    $ok.Add_Click({
        $r = & $collect
        $miss = @()
        if ($r['url'] -notmatch '^https?://') { $miss += 'Supabase-Adresse' }
        if (-not $r['key']) { $miss += 'Schlüssel' }
        if (-not $r['guild']) { $miss += 'Gilde' }
        if (-not $fields['password'].Text) { $miss += 'Schreib-Passwort' }
        if (-not $r['name']) { $miss += 'Name' }
        if (-not $r['svPath']) { $miss += 'WoW-Ordner' }
        if ($miss.Count -gt 0) { $status.Text = 'Bitte ausfüllen: ' + ($miss -join ', '); return }
        $dh = $fields['discord'].Text.Trim()
        if ($dh -and -not (Test-NexWebhookUrl $dh)) { $status.Text = 'Discord-Webhook: Die Adresse sieht nicht richtig aus (https://discord.com/api/webhooks/…). Feld leer lassen, wenn du keinen willst.'; return }
        try { Set-NexAutostart $auto.Checked } catch { Write-NexLog ('Autostart: ' + $_.Exception.Message) }
        $script:setupResult = $r
        $f.Close()
    })
    $cancel.Add_Click({ $f.Close() })
    [void]$f.ShowDialog()
    return $script:setupResult
}

# Einstellungen "Sicherung per Mail" (1.6). Rueckgabe: geaenderte Einstellungen oder $null
function Show-NexBackupSetup($Raw) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'NexLoot Companion - Sicherung per Mail'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object System.Drawing.Size(560, 430)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $f.Icon = New-NexIcon ([System.Drawing.Color]::FromArgb(255, 255, 209, 0))
    $f.TopMost = $true
    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'Jeden Abend schickt die Companion-App eine Sicherung der Datenbank als SQL-Datei (erst CREATE TABLE, dann der Stand) per Mail. Fehlt ein Abend (PC aus), wird er beim nächsten Start nachgeholt.'
    $intro.SetBounds(14, 12, 532, 48); $f.Controls.Add($intro)
    $on = New-Object System.Windows.Forms.CheckBox
    $on.Text = 'Jeden Abend eine Sicherung per Mail schicken'; $on.SetBounds(14, 64, 400, 22); $f.Controls.Add($on)
    $fields = @{}
    $y = 96
    foreach ($def in @(@('Empfänger:', 'mailTo', $false), @('Absender (Gmail-Adresse):', 'mailFrom', $false), @('App-Passwort:', 'mailPass', $true), @('Mailserver:', 'mailHost', $false))) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $def[0]; $l.SetBounds(14, $y + 3, 170, 20); $f.Controls.Add($l)
        $t = New-Object System.Windows.Forms.TextBox
        $t.SetBounds(186, $y, 360, 24)
        if ($def[2]) { $t.UseSystemPasswordChar = $true }
        $f.Controls.Add($t); $fields[$def[1]] = $t
        $y += 32
    }
    $fields['mailHost'].Width = 250
    $lp = New-Object System.Windows.Forms.Label
    $lp.Text = 'Port:'; $lp.SetBounds(444, $y - 32 + 3, 36, 20); $f.Controls.Add($lp)
    $port = New-Object System.Windows.Forms.TextBox
    $port.SetBounds(482, $y - 32, 64, 24); $f.Controls.Add($port)
    $lh = New-Object System.Windows.Forms.Label
    $lh.Text = 'Uhrzeit (ab):'; $lh.SetBounds(14, $y + 3, 170, 20); $f.Controls.Add($lh)
    $hour = New-Object System.Windows.Forms.NumericUpDown
    $hour.Minimum = 0; $hour.Maximum = 23; $hour.SetBounds(186, $y, 60, 24); $f.Controls.Add($hour)
    $lu = New-Object System.Windows.Forms.Label
    $lu.Text = 'Uhr'; $lu.SetBounds(252, $y + 3, 60, 20); $f.Controls.Add($lu)
    $y += 36
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Gmail: Das normale Passwort geht nicht. Unter myaccount.google.com/apppasswords ein App-Passwort erstellen (dafür muss die 2-Schritt-Bestätigung an sein) und hier eintragen. Es wird verschlüsselt gespeichert.'
    $hint.SetBounds(14, $y, 532, 48); $hint.ForeColor = [System.Drawing.Color]::FromArgb(255, 90, 90, 90); $f.Controls.Add($hint)
    $y += 54
    $status = New-Object System.Windows.Forms.Label
    $status.SetBounds(14, $y, 532, 58); $status.ForeColor = [System.Drawing.Color]::FromArgb(255, 60, 60, 60); $f.Controls.Add($status)
    $test = New-Object System.Windows.Forms.Button
    $test.Text = 'Test-Sicherung jetzt senden'; $test.SetBounds(14, 384, 190, 30); $f.Controls.Add($test)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Speichern'; $ok.SetBounds(346, 384, 96, 30); $f.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Abbrechen'; $cancel.SetBounds(450, 384, 96, 30); $f.Controls.Add($cancel)
    $f.AcceptButton = $ok; $f.CancelButton = $cancel
    $mc = Get-NexMailCfg $Raw
    $on.Checked = $mc.on
    $fields['mailTo'].Text = $mc.to; $fields['mailFrom'].Text = $mc.from; $fields['mailPass'].Text = $mc.pass; $fields['mailHost'].Text = $mc.host
    $port.Text = [string]$mc.port; $hour.Value = [decimal]$mc.hour
    $collect = {
        $r = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($k in @($Raw.Keys)) { $r[$k] = $Raw[$k] }
        $r['mailOn'] = [bool]$on.Checked
        $r['mailTo'] = $fields['mailTo'].Text.Trim()
        $r['mailFrom'] = $fields['mailFrom'].Text.Trim()
        $r['mailPass'] = Protect-NexSecret ($fields['mailPass'].Text.Replace(' ', '')) # Google zeigt das App-Passwort in Vierergruppen
        $r['mailHost'] = $fields['mailHost'].Text.Trim()
        $pp = 0; [void][int]::TryParse($port.Text.Trim(), [ref]$pp); if ($pp -le 0) { $pp = 587 }
        $r['mailPort'] = $pp
        $r['mailHour'] = [int]$hour.Value
        return $r
    }
    $check = {
        param($r)
        $miss = @()
        if ($r['mailTo'] -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $miss += 'Empfänger' }
        if ($r['mailFrom'] -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $miss += 'Absender' }
        if (-not (Unprotect-NexSecret ([string]$r['mailPass']))) { $miss += 'App-Passwort' }
        if (-not $r['mailHost']) { $miss += 'Mailserver' }
        return $miss
    }
    $test.Add_Click({
        $r = & $collect
        $miss = & $check $r
        if ($miss.Count -gt 0) { $status.Text = 'Bitte ausfüllen: ' + ($miss -join ', '); return }
        $status.Text = 'Sende Test-Sicherung …'; $f.Refresh()
        $ctx = @{ cfg = $script:cfg; state = (New-Object System.Collections.Specialized.OrderedDictionary); dataDir = $script:DataDir }
        $b = Invoke-NexBackup $ctx (Get-NexMailCfg $r) -Force
        if ($b.Sent) { $status.Text = $b.Message + ' Schau ins Postfach (auch in den Spam-Ordner).' } else { $status.Text = $b.Error }
        Write-NexLog ('Test: ' + $b.Message + $b.Error)
    })
    $script:backupResult = $null
    $ok.Add_Click({
        $r = & $collect
        if ($r['mailOn']) {
            $miss = & $check $r
            if ($miss.Count -gt 0) { $status.Text = 'Bitte ausfüllen: ' + ($miss -join ', '); return }
        }
        $script:backupResult = $r
        $f.Close()
    })
    $cancel.Add_Click({ $f.Close() })
    [void]$f.ShowDialog()
    return $script:backupResult
}

function Show-NexBalloon([string] $Text, [string] $Kind = 'Info') {
    if (-not $script:ni) { return }
    $script:ni.ShowBalloonTip(6000, 'NexLoot Companion', $Text, [System.Windows.Forms.ToolTipIcon]::$Kind)
}

function Set-NexStatus([string] $Text, [bool] $IsError) {
    $script:statusText = $Text
    $script:statusAt = [DateTime]::Now
    $short = $Text
    if ($short.Length -gt 50) { $short = $short.Substring(0, 50) + '...' }
    $script:ni.Text = ('NexLoot: ' + $short).Substring(0, [Math]::Min(63, ('NexLoot: ' + $short).Length))
    $script:miStatus.Text = [DateTime]::Now.ToString('HH:mm') + '  ' + $short
    if ($IsError) { $script:ni.Icon = $script:iconErr } else { $script:ni.Icon = $script:iconOk }
}

function Invoke-NexTick([switch] $Force) {
    $now = [DateTime]::Now
    $mt = 0L
    if ($script:cfg.svPath -and (Test-Path -LiteralPath $script:cfg.svPath)) { $mt = (Get-Item -LiteralPath $script:cfg.svPath).LastWriteTimeUtc.Ticks }
    if ($mt -ne $script:lastSvMtime) { $script:lastSvMtime = $mt; $script:svChangedAt = $now }
    $due = $Force -or ($null -ne $script:svChangedAt -and ($now - $script:svChangedAt).TotalSeconds -ge 2) -or (($now - $script:lastSync).TotalSeconds -ge 30)
    if (-not $due) { return }
    $script:svChangedAt = $null
    $script:lastSync = $now
    try {
        $ctx = @{ cfg = $script:cfg; state = $script:state; dataDir = $script:DataDir }
        $res = Invoke-NexSync $ctx
        if ($script:cfg.discordUrl) {
            try {
                $dres = Invoke-NexDiscord $ctx $res
                if ($dres.Posted -gt 0) { Write-NexLog $dres.Message; Show-NexBalloon $dres.Message 'Info' }
                if ($dres.Error -and $dres.Error -ne $script:lastDiscordError) { Write-NexLog $dres.Error; Show-NexBalloon $dres.Error 'Warning' }
                $script:lastDiscordError = $dres.Error
            } catch { Write-NexLog ('Discord: ' + $_.Exception.Message.Replace($script:cfg.discordUrl, '(Webhook)')) }
        }
        if ($null -ne $script:mail -and $script:mail.on) {
            try {
                $bres = Invoke-NexBackup $ctx $script:mail
                if ($bres.Sent) { Write-NexLog $bres.Message }
                if ($bres.Error -and $bres.Error -ne $script:lastBackupError) { Write-NexLog $bres.Error; Show-NexBalloon $bres.Error 'Warning' }
                if ($bres.Sent -or $bres.Error) { $script:lastBackupError = $bres.Error }
            } catch { Write-NexLog ('Sicherung per Mail: ' + $_.Exception.Message) }
        }
        Save-NexState $script:state
        $script:errCount = 0
        if ($res.Action -ne 'none' -or $script:lastAction -ne 'none') { Write-NexLog ($res.Action + ': ' + $res.Message) }
        $script:lastAction = $res.Action
        $script:lastRes = $res
        Set-NexStatus $res.Message ($res.Action -eq 'svError')
        if ($res.Conflict) {
            $script:lastReport = $res.ReportPath
            Show-NexBalloon 'Konflikt: Spiel und Webapp wurden getrennt geändert. Es gilt der Webapp-Stand. Klicken für den Bericht.' 'Warning'
        } elseif ($res.Notify) {
            $script:lastReport = $null
            Show-NexBalloon ($res.Message + ' Im Spiel: /reload') 'Info'
        }
        $script:lastError = ''
    } catch {
        $msg = $_.Exception.Message
        $script:errCount++
        Write-NexLog ('Fehler: ' + $msg)
        Set-NexStatus ('Fehler: ' + $msg) $true
        if ($msg -ne $script:lastError -and ($script:errCount -ge 3 -or $msg -match 'Passwort|API key|JWT')) {
            $script:lastError = $msg
            Show-NexBalloon ('Abgleich klappt nicht: ' + $msg) 'Error'
        }
    }
}

function Show-NexStatusBox {
    $lines = @()
    $lines += 'Status: ' + $script:statusText
    if ($script:statusAt) { $lines += 'Zuletzt geprüft: ' + $script:statusAt.ToString('dd.MM.yyyy HH:mm:ss') }
    if ($script:lastRes) {
        if ($null -ne $script:lastRes.LocalRev) { $lines += 'Stand im Spiel (zuletzt gespeichert): ' + $script:lastRes.LocalRev }
        if ($null -ne $script:lastRes.WebRev) { $lines += 'Stand in der Webapp: ' + $script:lastRes.WebRev }
    }
    $lines += ''
    $lines += 'WoW-Daten: ' + $script:cfg.svPath
    $lines += 'Addon-Ordner: ' + $script:cfg.addonPath
    $lines += 'Gilde: ' + $script:cfg.guild + '   Name: ' + $script:cfg.name
    if ($script:cfg.discordUrl) { $lines += 'Discord: Webhook eingetragen – nach jedem Raid eine Zusammenfassung, mittwochs der Verfall' } else { $lines += 'Discord: aus (kein Webhook eingetragen)' }
    if ($null -ne $script:mail -and $script:mail.on) {
        $bl = 'Sicherung per Mail: an ' + $script:mail.to + ', jeden Abend ab ' + $script:mail.hour + ' Uhr'
        $ba = Get-NexLong $script:state['backupAt']
        if ($ba -gt 0) { $bl += ' (zuletzt ' + (Format-NexDate $ba 'dd.MM. HH:mm') + ')' }
        $lines += $bl
    } else { $lines += 'Sicherung per Mail: aus' }
    $lines += ''
    $lines += 'WoW speichert die NexLoot-Daten beim Ausloggen und bei /reload. Neue Stände aus der Webapp'
    $lines += 'werden beim nächsten Einloggen bzw. /reload übernommen.'
    [void][System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), 'NexLoot Companion ' + $script:AppVersion, 'OK', 'Information')
}

function Start-NexTray {
    $script:iconOk = New-NexIcon ([System.Drawing.Color]::FromArgb(255, 255, 209, 0))
    $script:iconErr = New-NexIcon ([System.Drawing.Color]::FromArgb(255, 220, 60, 60))
    $script:ni = New-Object System.Windows.Forms.NotifyIcon
    $script:ni.Icon = $script:iconOk
    $script:ni.Text = 'NexLoot Companion'
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:miStatus = New-Object System.Windows.Forms.ToolStripMenuItem 'Startet …'
    $script:miStatus.Enabled = $false
    [void]$menu.Items.Add($script:miStatus)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Jetzt abgleichen'
    $mi.Add_Click({ Invoke-NexTick -Force }); [void]$menu.Items.Add($mi)
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Status anzeigen'
    $mi.Add_Click({ Show-NexStatusBox }); [void]$menu.Items.Add($mi)
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Letzten Raid nach Discord senden'
    $mi.Add_Click({
        if (-not $script:cfg.discordUrl) { Show-NexBalloon 'Kein Discord-Webhook eingetragen (Einstellungen).' 'Warning'; return }
        $t = $null; if ($script:lastRes) { $t = $script:lastRes.Target }
        $last = $null
        if ($null -ne $t) { foreach ($e in $t['sessions']) { if ((Get-NexLong $e['stop']) -gt 0 -and ($null -eq $last -or (Get-NexLong $e['stop']) -gt (Get-NexLong $last['stop']))) { $last = $e } } }
        if ($null -eq $last) { Show-NexBalloon 'Noch kein beendeter Raid bekannt.' 'Info'; return }
        $r = Send-NexDiscordAll $script:cfg.discordUrl (New-NexDiscordMessages $t $last ([string]$script:cfg.webUrl))
        if ($r.Ok) { Show-NexBalloon ('Discord: „' + [string]$last['name'] + '“ gesendet.') 'Info' } else { Show-NexBalloon $r.Message 'Warning' }
    })
    [void]$menu.Items.Add($mi)
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Webapp öffnen'
    $mi.Add_Click({ if ($script:cfg.webUrl) { Start-Process $script:cfg.webUrl } else { Show-NexBalloon 'Keine Webapp-Adresse eingetragen (Einstellungen).' } })
    [void]$menu.Items.Add($mi)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Einstellungen …'
    $mi.Add_Click({
        $r = Show-NexSetup $script:raw
        if ($null -ne $r) {
            $script:raw = $r; Save-NexConfig $r; $script:cfg = Get-NexCfg $r; $script:mail = Get-NexMailCfg $r
            $keep = New-Object System.Collections.Specialized.OrderedDictionary
            foreach ($k in @('backupSlot', 'backupAt', 'decayDone', 'decayBy')) { if ($script:state.Contains($k)) { $keep[$k] = $script:state[$k] } }
            $script:state = $keep
            Invoke-NexTick -Force
        }
    })
    [void]$menu.Items.Add($mi)
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Sicherung per Mail …'
    $mi.Add_Click({
        $r = Show-NexBackupSetup $script:raw
        if ($null -ne $r) {
            $script:raw = $r; Save-NexConfig $r; $script:mail = Get-NexMailCfg $r
            if ($script:mail.on) { Show-NexBalloon ('Sicherung per Mail ist an: jeden Abend ab ' + $script:mail.hour + ' Uhr an ' + $script:mail.to + '.') 'Info' }
            Invoke-NexTick -Force
        }
    })
    [void]$menu.Items.Add($mi)
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Sicherung jetzt per Mail senden'
    $mi.Add_Click({
        if ($null -eq $script:mail -or -not $script:mail.to) { Show-NexBalloon 'Sicherung per Mail ist noch nicht eingerichtet (Rechtsklick → Sicherung per Mail …).' 'Warning'; return }
        $ctx = @{ cfg = $script:cfg; state = $script:state; dataDir = $script:DataDir }
        $b = Invoke-NexBackup $ctx $script:mail -Force
        if ($b.Sent) { Write-NexLog $b.Message; Show-NexBalloon $b.Message 'Info'; Save-NexState $script:state } else { Write-NexLog $b.Error; Show-NexBalloon $b.Error 'Warning' }
    })
    [void]$menu.Items.Add($mi)
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Verbindungscode für andere Offiziere kopieren'
    $mi.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText((New-NexConnectionCode $script:raw))
        Show-NexBalloon 'Verbindungscode kopiert. Nur privat weitergeben – er enthält das Schreib-Passwort!' 'Warning'
    })
    [void]$menu.Items.Add($mi)
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Protokoll öffnen'
    $mi.Add_Click({ if (Test-Path -LiteralPath $script:LogPath) { Start-Process notepad.exe ('"' + $script:LogPath + '"') } })
    [void]$menu.Items.Add($mi)
    $script:miAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'Mit Windows starten'
    $script:miAuto.Checked = Test-NexAutostart
    $script:miAuto.Add_Click({ try { Set-NexAutostart (-not $script:miAuto.Checked); $script:miAuto.Checked = Test-NexAutostart } catch { Show-NexBalloon $_.Exception.Message 'Error' } })
    [void]$menu.Items.Add($script:miAuto)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Beenden'
    $mi.Add_Click({ $script:timer.Stop(); $script:ni.Visible = $false; [System.Windows.Forms.Application]::Exit() })
    [void]$menu.Items.Add($mi)
    $script:ni.ContextMenuStrip = $menu
    $script:ni.Add_DoubleClick({ Show-NexStatusBox })
    $script:ni.Add_BalloonTipClicked({ if ($script:lastReport -and (Test-Path -LiteralPath $script:lastReport)) { Start-Process notepad.exe ('"' + $script:lastReport + '"') } })
    $script:ni.Visible = $true

    $script:lastSvMtime = -1L
    $script:svChangedAt = $null
    $script:lastSync = [DateTime]::MinValue
    $script:lastAction = ''
    $script:errCount = 0
    $script:lastError = ''
    $script:lastDiscordError = ''
    $script:lastBackupError = ''
    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 3000
    $script:timer.Add_Tick({ Invoke-NexTick })
    $script:timer.Start()
    Show-NexBalloon 'Läuft im Hintergrund (Symbol unten rechts). Rechtsklick für das Menü.'
    Invoke-NexTick -Force
    [System.Windows.Forms.Application]::Run()
    $script:ni.Dispose()
}

# ---------------------------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------------------------
if ($NoUi) { return }

# 1.6.2: falls doch ein Konsolenfenster offen ist (Start ohne die .bat), es verstecken
try {
    Add-Type -Namespace NexLoot -Name Win -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);' -ErrorAction Stop
    $cw = [NexLoot.Win]::GetConsoleWindow()
    if ($cw -ne [System.IntPtr]::Zero) { [void][NexLoot.Win]::ShowWindow($cw, 0) }
} catch { }
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\NexLootCompanion', [ref]$created)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
if (-not $created) {
    $hint = 'Die NexLoot Companion-App läuft schon (Symbol unten rechts in der Taskleiste).'
    if ($Setup) { $hint += ' Die Einstellungen öffnest du dort mit Rechtsklick → Einstellungen …' }
    [void][System.Windows.Forms.MessageBox]::Show($hint, 'NexLoot Companion', 'OK', 'Information')
    return
}
try {
    $script:raw = Read-NexConfig
    if ($null -eq $script:raw -or $Setup) {
        $r = Show-NexSetup $script:raw
        if ($null -eq $r) { return }
        $script:raw = $r
        Save-NexConfig $r
    }
    $script:cfg = Get-NexCfg $script:raw
    $script:mail = Get-NexMailCfg $script:raw
    $script:state = Read-NexState
    # 1.6.2: Autostart-Verknuepfung aus aelteren Versionen auf den unsichtbaren Start umstellen
    try { if (Test-NexAutostart) { Set-NexAutostart $true } } catch { Write-NexLog ('Autostart: ' + $_.Exception.Message) }
    Write-NexLog ('Start (Version ' + $script:AppVersion + ')')
    Start-NexTray
} catch {
    Write-NexLog ('Abbruch: ' + $_.Exception.Message)
    [void][System.Windows.Forms.MessageBox]::Show('NexLoot Companion: ' + $_.Exception.Message, 'NexLoot Companion', 'OK', 'Error')
} finally {
    $mutex.Dispose()
}
