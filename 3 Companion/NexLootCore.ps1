# NexLoot Companion - Kern (Lesen/Schreiben der Addon-Dateien, Abgleich mit der Webapp)
# Laeuft mit Windows PowerShell 5.1 (in Windows enthalten) und PowerShell 7.

$script:NexInv = [Globalization.CultureInfo]::InvariantCulture
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------------------------------------
# Lua (SavedVariables) lesen
# ---------------------------------------------------------------------------------------------
class NexLuaReader {
    [System.Text.RegularExpressions.MatchCollection] $Toks
    [int] $Pos

    NexLuaReader([string] $src) {
        $pattern = '(?<c>--[^\r\n]*)|(?<s>"(?:[^"\\]|\\.)*")|(?<n>-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)|(?<p>[{}\[\]=,;])|(?<i>[A-Za-z_][A-Za-z0-9_]*)|(?<x>\S)'
        $this.Toks = [regex]::Matches($src, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $this.Pos = 0
    }

    [System.Text.RegularExpressions.Match] Next() {
        while ($this.Pos -lt $this.Toks.Count) {
            $m = $this.Toks[$this.Pos]
            $this.Pos++
            if (-not $m.Groups['c'].Success) { return $m }
        }
        return $null
    }

    [System.Text.RegularExpressions.Match] Peek() {
        $save = $this.Pos
        $m = $this.Next()
        $this.Pos = $save
        return $m
    }

    [void] Expect([string] $p) {
        $m = $this.Next()
        if ($null -eq $m -or $m.Value -ne $p) {
            $got = '(Ende)'
            if ($null -ne $m) { $got = $m.Value }
            throw "Lua: '$p' erwartet, gefunden: $got"
        }
    }

    static [string] Unescape([string] $s) {
        $inner = $s.Substring(1, $s.Length - 2)
        if ($inner.IndexOf('\') -lt 0) { return $inner }
        $sb = New-Object System.Text.StringBuilder
        $i = 0
        while ($i -lt $inner.Length) {
            $ch = $inner[$i]
            if ($ch -ne '\' -or $i + 1 -ge $inner.Length) { [void]$sb.Append($ch); $i++; continue }
            $n = $inner[$i + 1]
            if ([char]::IsDigit($n)) {
                $j = $i + 1
                $num = ''
                while ($j -lt $inner.Length -and $num.Length -lt 3 -and [char]::IsDigit($inner[$j])) { $num += $inner[$j]; $j++ }
                [void]$sb.Append([char][int]$num)
                $i = $j
                continue
            }
            switch -CaseSensitive ([string]$n) {
                'n' { [void]$sb.Append("`n") }
                't' { [void]$sb.Append("`t") }
                'r' { [void]$sb.Append("`r") }
                'a' { [void]$sb.Append([char]7) }
                'b' { [void]$sb.Append([char]8) }
                'f' { [void]$sb.Append([char]12) }
                'v' { [void]$sb.Append([char]11) }
                "`r" {
                    [void]$sb.Append("`n")
                    if ($i + 2 -lt $inner.Length -and $inner[$i + 2] -eq "`n") { $i++ }
                }
                "`n" { [void]$sb.Append("`n") }
                default { [void]$sb.Append($n) }
            }
            $i += 2
        }
        return $sb.ToString()
    }

    [object] Value() {
        $m = $this.Next()
        if ($null -eq $m) { throw 'Lua: Wert erwartet, Dateiende gefunden' }
        if ($m.Groups['s'].Success) { return [NexLuaReader]::Unescape($m.Value) }
        if ($m.Groups['n'].Success) {
            $v = $m.Value
            if ($v -match '^-?\d+$' -and $v.Length -lt 19) { return [long]::Parse($v, [Globalization.CultureInfo]::InvariantCulture) }
            return [double]::Parse($v, [Globalization.CultureInfo]::InvariantCulture)
        }
        if ($m.Groups['i'].Success) {
            if ($m.Value -ceq 'true') { return $true }
            if ($m.Value -ceq 'false') { return $false }
            if ($m.Value -ceq 'nil') { return $null }
            throw "Lua: unerwartetes Wort '$($m.Value)'"
        }
        if ($m.Value -eq '{') { return $this.Table() }
        throw "Lua: unerwartetes Zeichen '$($m.Value)'"
    }

    [object] Table() {
        $keys = New-Object System.Collections.ArrayList
        $vals = New-Object System.Collections.ArrayList
        $n = 0
        while ($true) {
            $t = $this.Peek()
            if ($null -eq $t) { throw 'Lua: "}" fehlt' }
            if ($t.Value -eq '}') { [void]$this.Next(); break }
            $key = $null
            if ($t.Value -eq '[') {
                [void]$this.Next()
                $key = $this.Value()
                $this.Expect(']')
                $this.Expect('=')
            } elseif ($t.Groups['i'].Success -and $t.Value -cne 'true' -and $t.Value -cne 'false' -and $t.Value -cne 'nil') {
                $save = $this.Pos
                [void]$this.Next()
                $eq = $this.Peek()
                if ($null -ne $eq -and $eq.Value -eq '=') { [void]$this.Next(); $key = $t.Value } else { $this.Pos = $save }
            }
            if ($null -eq $key) { $n++; $key = [long]$n }
            $val = $this.Value()
            if ($null -ne $val) { [void]$keys.Add($key); [void]$vals.Add($val) }
            $sep = $this.Peek()
            if ($null -ne $sep -and ($sep.Value -eq ',' -or $sep.Value -eq ';')) { [void]$this.Next() }
        }
        # Liste (Schluessel 1..n) oder Tabelle mit Namen
        $isList = $keys.Count -gt 0
        for ($k = 0; $k -lt $keys.Count -and $isList; $k++) {
            $kk = $keys[$k]
            if (-not ($kk -is [long] -or $kk -is [int] -or $kk -is [double])) { $isList = $false; break }
        }
        if ($isList) {
            $byIdx = @{}
            foreach ($k in 0..($keys.Count - 1)) { $byIdx[[long]$keys[$k]] = $vals[$k] }
            for ($k = 1; $k -le $keys.Count; $k++) { if (-not $byIdx.ContainsKey([long]$k)) { $isList = $false; break } }
            if ($isList) {
                $list = New-Object System.Collections.ArrayList
                for ($k = 1; $k -le $keys.Count; $k++) { [void]$list.Add($byIdx[[long]$k]) }
                return $list
            }
        }
        $map = New-Object System.Collections.Specialized.OrderedDictionary
        for ($k = 0; $k -lt $keys.Count; $k++) {
            $kk = $keys[$k]
            if ($kk -is [double]) { $kk = ([double]$kk).ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
            $map[[string]$kk] = $vals[$k]
        }
        return $map
    }
}

# Liest "NexLootDB = { ... }" aus dem Text einer SavedVariables-Datei
function ConvertFrom-NexLua([string] $Text, [string] $Name = 'NexLootDB') {
    $m = [regex]::Match($Text, '(?m)^\s*' + [regex]::Escape($Name) + '\s*=\s*')
    if (-not $m.Success) { return $null }
    $reader = [NexLuaReader]::new($Text.Substring($m.Index + $m.Length))
    $v = $reader.Value()
    return , $v
}

# ---------------------------------------------------------------------------------------------
# Lua schreiben (WebData.lua)
# ---------------------------------------------------------------------------------------------
function ConvertTo-NexLuaString([string] $s) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($c -eq 10) { [void]$sb.Append('\n') }
        elseif ($c -eq 13) { [void]$sb.Append('\r') }
        elseif ($c -lt 32 -or $c -eq 127) { [void]$sb.Append('\' + $c.ToString($script:NexInv)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Format-NexNumber($v) {
    if ($v -is [double] -or $v -is [single] -or $v -is [decimal]) {
        $d = [double]$v
        if ([math]::Floor($d) -eq $d -and [math]::Abs($d) -lt 1e15) { return ([long]$d).ToString($script:NexInv) }
        return $d.ToString('R', $script:NexInv)
    }
    return ([long]$v).ToString($script:NexInv)
}

function Test-NexNumber($v) {
    return ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] -or $v -is [single] -or $v -is [int16] -or $v -is [byte])
}

function Get-NexSortedKeys($dict) {
    $keys = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in $dict.Keys) { $keys.Add([string]$k) }
    $keys.Sort([StringComparer]::Ordinal)
    return , $keys
}

function Write-NexLuaValue($sb, $v, [int] $depth) {
    if ($null -eq $v) { [void]$sb.Append('nil'); return }
    if ($v -is [bool]) { if ($v) { [void]$sb.Append('true') } else { [void]$sb.Append('false') }; return }
    if (Test-NexNumber $v) { [void]$sb.Append((Format-NexNumber $v)); return }
    if ($v -is [string]) { [void]$sb.Append((ConvertTo-NexLuaString $v)); return }
    $ind = "`t" * ($depth + 1)
    if ($v -is [System.Collections.IDictionary]) {
        [void]$sb.Append("{`n")
        foreach ($k in (Get-NexSortedKeys $v)) {
            [void]$sb.Append($ind)
            if ($k -match '^-?\d{1,15}$') { [void]$sb.Append('[' + $k + '] = ') } else { [void]$sb.Append('[' + (ConvertTo-NexLuaString $k) + '] = ') }
            Write-NexLuaValue $sb $v[$k] ($depth + 1)
            [void]$sb.Append(",`n")
        }
        [void]$sb.Append(("`t" * $depth) + '}')
        return
    }
    if ($v -is [System.Collections.IEnumerable]) {
        [void]$sb.Append("{`n")
        foreach ($x in $v) {
            [void]$sb.Append($ind)
            Write-NexLuaValue $sb $x ($depth + 1)
            [void]$sb.Append(",`n")
        }
        [void]$sb.Append(("`t" * $depth) + '}')
        return
    }
    [void]$sb.Append((ConvertTo-NexLuaString ([string]$v)))
}

function ConvertTo-NexLua($v) {
    $sb = New-Object System.Text.StringBuilder
    Write-NexLuaValue $sb $v 0
    return $sb.ToString()
}

# ---------------------------------------------------------------------------------------------
# JSON (eigener, sortierter Writer: gleiche Daten = gleicher Text = gleicher Hash)
# ---------------------------------------------------------------------------------------------
function ConvertTo-NexJsonString([string] $s) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($c -lt 32 -or $c -eq 0x2028 -or $c -eq 0x2029) { [void]$sb.Append('\u' + $c.ToString('x4')) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Write-NexJsonValue($sb, $v) {
    if ($null -eq $v) { [void]$sb.Append('null'); return }
    if ($v -is [bool]) { if ($v) { [void]$sb.Append('true') } else { [void]$sb.Append('false') }; return }
    if (Test-NexNumber $v) { [void]$sb.Append((Format-NexNumber $v)); return }
    if ($v -is [string]) { [void]$sb.Append((ConvertTo-NexJsonString $v)); return }
    if ($v -is [System.Collections.IDictionary]) {
        [void]$sb.Append('{')
        $first = $true
        foreach ($k in (Get-NexSortedKeys $v)) {
            if (-not $first) { [void]$sb.Append(',') }
            $first = $false
            [void]$sb.Append((ConvertTo-NexJsonString $k))
            [void]$sb.Append(':')
            Write-NexJsonValue $sb $v[$k]
        }
        [void]$sb.Append('}')
        return
    }
    if ($v -is [System.Management.Automation.PSCustomObject]) { Write-NexJsonValue $sb (ConvertTo-NexPlain $v); return }
    if ($v -is [System.Collections.IEnumerable]) {
        [void]$sb.Append('[')
        $first = $true
        foreach ($x in $v) {
            if (-not $first) { [void]$sb.Append(',') }
            $first = $false
            Write-NexJsonValue $sb $x
        }
        [void]$sb.Append(']')
        return
    }
    [void]$sb.Append((ConvertTo-NexJsonString ([string]$v)))
}

function ConvertTo-NexJson($v) {
    $sb = New-Object System.Text.StringBuilder
    Write-NexJsonValue $sb $v
    return $sb.ToString()
}

# PSCustomObject (aus ConvertFrom-Json) -> OrderedDictionary / ArrayList
function ConvertTo-NexPlain($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [System.Management.Automation.PSCustomObject]) {
        $map = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($p in $v.PSObject.Properties) { $map[$p.Name] = ConvertTo-NexPlain $p.Value }
        return $map
    }
    if ($v -is [System.Collections.IDictionary]) {
        $map = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($k in $v.Keys) { $map[[string]$k] = ConvertTo-NexPlain $v[$k] }
        return $map
    }
    if ($v -is [string]) { return $v }
    if ($v -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($x in $v) { [void]$list.Add((ConvertTo-NexPlain $x)) }
        return , $list
    }
    return $v
}

# Eigener JSON-Leser (gleiches Verhalten in PowerShell 5.1 und 7, keine Groessenbegrenzung)
class NexJsonReader {
    [System.Text.RegularExpressions.MatchCollection] $Toks
    [int] $Pos

    NexJsonReader([string] $src) {
        $pattern = '(?<s>"(?:[^"\\]|\\.)*")|(?<n>-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|(?<p>[{}\[\]:,])|(?<i>true|false|null)|(?<x>\S)'
        $this.Toks = [regex]::Matches($src, $pattern)
        $this.Pos = 0
    }

    [System.Text.RegularExpressions.Match] Next() {
        if ($this.Pos -ge $this.Toks.Count) { throw 'JSON: unerwartetes Ende' }
        $m = $this.Toks[$this.Pos]
        $this.Pos++
        return $m
    }

    static [string] Unescape([string] $s) {
        $inner = $s.Substring(1, $s.Length - 2)
        if ($inner.IndexOf('\') -lt 0) { return $inner }
        $sb = New-Object System.Text.StringBuilder
        $k = 0
        while ($k -lt $inner.Length) {
            $ch = $inner[$k]
            if ($ch -ne '\') { [void]$sb.Append($ch); $k++; continue }
            $e = $inner[$k + 1]
            switch -CaseSensitive ([string]$e) {
                'n' { [void]$sb.Append("`n") }
                't' { [void]$sb.Append("`t") }
                'r' { [void]$sb.Append("`r") }
                'b' { [void]$sb.Append([char]8) }
                'f' { [void]$sb.Append([char]12) }
                'u' { [void]$sb.Append([char][Convert]::ToInt32($inner.Substring($k + 2, 4), 16)); $k += 4 }
                default { [void]$sb.Append($e) }
            }
            $k += 2
        }
        return $sb.ToString()
    }

    [object] Value() {
        $m = $this.Next()
        if ($m.Groups['s'].Success) { return [NexJsonReader]::Unescape($m.Value) }
        if ($m.Groups['n'].Success) {
            $v = $m.Value
            if ($v -match '^-?\d+$' -and $v.Length -lt 19) { return [long]::Parse($v, [Globalization.CultureInfo]::InvariantCulture) }
            return [double]::Parse($v, [Globalization.CultureInfo]::InvariantCulture)
        }
        if ($m.Groups['i'].Success) {
            if ($m.Value -ceq 'true') { return $true }
            if ($m.Value -ceq 'false') { return $false }
            return $null
        }
        if ($m.Value -eq '{') {
            $map = New-Object System.Collections.Specialized.OrderedDictionary
            if ($this.Toks[$this.Pos].Value -eq '}') { $this.Pos++; return $map }
            while ($true) {
                $k = $this.Next()
                if (-not $k.Groups['s'].Success) { throw 'JSON: Name erwartet' }
                if ($this.Next().Value -ne ':') { throw 'JSON: ":" erwartet' }
                $map[[NexJsonReader]::Unescape($k.Value)] = $this.Value()
                $sep = $this.Next().Value
                if ($sep -eq '}') { break }
                if ($sep -ne ',') { throw 'JSON: "," oder "}" erwartet' }
            }
            return $map
        }
        if ($m.Value -eq '[') {
            $list = New-Object System.Collections.ArrayList
            if ($this.Toks[$this.Pos].Value -eq ']') { $this.Pos++; return $list }
            while ($true) {
                [void]$list.Add($this.Value())
                $sep = $this.Next().Value
                if ($sep -eq ']') { break }
                if ($sep -ne ',') { throw 'JSON: "," oder "]" erwartet' }
            }
            return $list
        }
        throw "JSON: unerwartetes Zeichen '$($m.Value)'"
    }
}

function ConvertFrom-NexJson([string] $Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $r = [NexJsonReader]::new($Text)
    $v = $r.Value()
    return , $v
}

function Get-NexSha256([string] $Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

# ---------------------------------------------------------------------------------------------
# NexLoot-Daten vereinheitlichen
# ---------------------------------------------------------------------------------------------
function Get-NexField($d, [string] $k) {
    if ($null -eq $d -or -not ($d -is [System.Collections.IDictionary])) { return $null }
    if ($d.Contains($k)) { return , $d[$k] }
    return $null
}

function ConvertTo-NexList($v) {
    $list = New-Object System.Collections.ArrayList
    if ($null -eq $v) { return , $list }
    if ($v -is [System.Collections.IDictionary]) {
        # Tabelle mit Luecken: nach Zahlen sortiert
        $pairs = @()
        foreach ($k in $v.Keys) { $n = 0L; if ([long]::TryParse([string]$k, [ref]$n)) { $pairs += , @($n, $v[$k]) } }
        foreach ($p in ($pairs | Sort-Object { $_[0] })) { [void]$list.Add($p[1]) }
        return , $list
    }
    if ($v -is [string]) { return , $list }
    foreach ($x in $v) { [void]$list.Add($x) }
    return , $list
}

function ConvertTo-NexMap($v) {
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    if ($v -is [System.Collections.IDictionary]) { foreach ($k in $v.Keys) { $map[[string]$k] = $v[$k] } }
    elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
        $i = 0
        foreach ($x in $v) { $i++; $map[[string]$i] = $x }
    }
    return $map
}

function Get-NexLong($v, [long] $default = 0) {
    if ($null -eq $v) { return $default }
    if (Test-NexNumber $v) { return [long][math]::Floor([double]$v) }
    $n = 0L
    if ([long]::TryParse([string]$v, [ref]$n)) { return $n }
    return $default
}

# Namen aus { Name = true } (Lua) bzw. [ Name, ... ] (JSON) -> sortierte Liste ohne Doppelte
function Get-NexNames($v) {
    $set = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    if ($v -is [System.Collections.IDictionary]) {
        foreach ($k in $v.Keys) { if ($v[$k] -eq $true -and ([string]$k) -ne '') { [void]$set.Add([string]$k) } }
    } elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
        foreach ($n in $v) { if ($n -is [string] -and $n -ne '') { [void]$set.Add($n) } }
    }
    $list = New-Object System.Collections.ArrayList
    foreach ($n in $set) { [void]$list.Add($n) }
    return , $list
}

# NexLootDB (aus der SavedVariables-Datei) bzw. Webapp-Daten -> einheitlicher Stand
function ConvertTo-NexState($db, [long] $rev = -1) {
    if (-not ($db -is [System.Collections.IDictionary])) { return $null }
    $st = New-Object System.Collections.Specialized.OrderedDictionary
    if ($rev -ge 0) { $st['rev'] = $rev } else { $st['rev'] = Get-NexLong (Get-NexField $db 'rev') }
    $coins = New-Object System.Collections.Specialized.OrderedDictionary
    $c = ConvertTo-NexMap (Get-NexField $db 'coins')
    foreach ($k in $c.Keys) { $coins[$k] = Get-NexLong $c[$k] }
    $st['coins'] = $coins
    $hist = New-Object System.Collections.ArrayList
    foreach ($h in (ConvertTo-NexList (Get-NexField $db 'history'))) {
        if (-not ($h -is [System.Collections.IDictionary])) { continue }
        $e = New-Object System.Collections.Specialized.OrderedDictionary
        $e['t'] = Get-NexLong (Get-NexField $h 't')
        $e['name'] = [string](Get-NexField $h 'name')
        $e['id'] = Get-NexLong (Get-NexField $h 'id')
        $e['cost'] = Get-NexLong (Get-NexField $h 'cost')
        $e['key'] = [string](Get-NexField $h 'key')
        $s = Get-NexField $h 's'
        if ($null -ne $s) { $e['s'] = Get-NexLong $s }
        $why = Get-NexField $h 'why' # Grund bei Coin-Aenderungen (ab NexLoot 0.15)
        if ($why -is [string] -and $why -ne '') { $e['why'] = $why }
        $pl = Get-NexField $h 'p' # wer "Coins fuer die Gruppe" bekommen hat (ab NexLoot 0.22)
        if ($null -ne $pl) {
            $names = New-Object System.Collections.ArrayList
            foreach ($n in (ConvertTo-NexList $pl)) { if ($n -is [string] -and $n -ne '') { [void]$names.Add($n) } }
            if ($names.Count -gt 0) { $e['p'] = $names }
        }
        if ($e['name'] -and $e['key']) { [void]$hist.Add($e) }
    }
    $st['history'] = $hist
    $st['lastDecay'] = Get-NexLong (Get-NexField $db 'lastDecay')
    $sess = New-Object System.Collections.ArrayList
    foreach ($e in (ConvertTo-NexList (Get-NexField $db 'sessions'))) {
        if (-not ($e -is [System.Collections.IDictionary])) { continue }
        $x = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($k in @('sid', 'start', 'stop', 'at')) { $v = Get-NexField $e $k; if ($null -ne $v) { $x[$k] = Get-NexLong $v } }
        foreach ($k in @('host', 'name')) { $v = Get-NexField $e $k; if ($null -ne $v) { $x[$k] = [string]$v } }
        $items = New-Object System.Collections.ArrayList
        foreach ($it in (ConvertTo-NexList (Get-NexField $e 'items'))) {
            if (-not ($it -is [System.Collections.IDictionary])) { continue }
            $y = New-Object System.Collections.Specialized.OrderedDictionary
            $v = Get-NexField $it 'id'; if ($null -ne $v) { $y['id'] = Get-NexLong $v }
            foreach ($k in @('w', 'r')) { $v = Get-NexField $it $k; if ($null -ne $v) { $y[$k] = [string]$v } }
            # 1.6: Antworten, Wuerfe und Notizen (ab NexLoot 0.25.1) - fuer die Webapp
            $am = ConvertTo-NexMap (Get-NexField $it 'a')
            if ($am.Count -gt 0) {
                $ao = New-Object System.Collections.Specialized.OrderedDictionary
                foreach ($n in (Get-NexSortedKeys $am)) { if ([string]$am[$n] -cmatch '^[A-Z]{1,6}$') { $ao[[string]$n] = [string]$am[$n] } }
                if ($ao.Count -gt 0) { $y['a'] = $ao }
            }
            $rm2 = ConvertTo-NexMap (Get-NexField $it 'ro')
            if ($rm2.Count -gt 0) {
                $roo = New-Object System.Collections.Specialized.OrderedDictionary
                foreach ($n in (Get-NexSortedKeys $rm2)) {
                    $pair = ConvertTo-NexList $rm2[$n]
                    if ($pair.Count -ge 1) { $roo[[string]$n] = [System.Collections.ArrayList]@((Get-NexLong $pair[0]), (Get-NexLong $(if ($pair.Count -ge 2) { $pair[1] } else { 0 }))) }
                }
                if ($roo.Count -gt 0) { $y['ro'] = $roo }
            }
            $ntm = ConvertTo-NexMap (Get-NexField $it 'nt')
            if ($ntm.Count -gt 0) {
                $nto = New-Object System.Collections.Specialized.OrderedDictionary
                foreach ($n in (Get-NexSortedKeys $ntm)) { if ($ntm[$n] -is [string] -and $ntm[$n] -ne '') { $nto[[string]$n] = [string]$ntm[$n] } }
                if ($nto.Count -gt 0) { $y['nt'] = $nto }
            }
            [void]$items.Add($y)
        }
        $x['items'] = $items
        # Teilnehmer (ab NexLoot 0.21, nur beim Offizier, der dabei war): im Spiel { Name = true }, in der Webapp eine Liste
        $mem = Get-NexNames (Get-NexField $e 'members')
        if ($mem.Count -gt 0) { $x['members'] = $mem }
        $v = Get-NexField $e 'dp'; if ($null -ne $v -and (Get-NexLong $v) -gt 0) { $x['dp'] = Get-NexLong $v } # nach Discord gepostet (Companion 1.3)
        $v = Get-NexField $e 'dps' # was gepostet wurde (Historie-Schluessel, Companion 1.5: fuer Korrekturen)
        if ($null -ne $v) {
            $dl = New-Object System.Collections.ArrayList
            foreach ($q in (ConvertTo-NexList $v)) { if ($q -is [string] -and $q -ne '') { [void]$dl.Add($q) } }
            $x['dps'] = $dl
        }
        if ($x.Contains('sid') -and $x.Contains('host')) { [void]$sess.Add($x) }
    }
    $st['sessions'] = $sess
    # Wipe-Marker (ab NexLoot 0.20): wer wann was geloescht hat - geloeschte Sessions nicht wieder einspielen
    $wipes = New-Object System.Collections.ArrayList
    foreach ($m in (ConvertTo-NexList (Get-NexField $db 'wipes'))) {
        if (-not ($m -is [System.Collections.IDictionary])) { continue }
        $x = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($k in @('at', 'from', 'to')) { $x[$k] = Get-NexLong (Get-NexField $m $k) }
        foreach ($k in @('what', 'r', 'by')) { $v = Get-NexField $m $k; if ($null -ne $v) { $x[$k] = [string]$v } }
        if ($x['at'] -gt 0) { [void]$wipes.Add($x) }
    }
    $st['wipes'] = $wipes
    $p = Get-NexField $db 'perm'
    if ($p -is [System.Collections.IDictionary] -and $null -ne (Get-NexField $p 'rev')) {
        $perm = New-Object System.Collections.Specialized.OrderedDictionary
        $perm['rev'] = Get-NexLong (Get-NexField $p 'rev')
        $perm['by'] = [string](Get-NexField $p 'by')
        $perm['at'] = Get-NexLong (Get-NexField $p 'at')
        $v = Get-NexField $p 'v'; if ($null -ne $v) { $perm['v'] = Get-NexLong $v }
        $r = New-Object System.Collections.ArrayList
        $rm = ConvertTo-NexMap (Get-NexField $p 'r')
        for ($i = 1; $i -le 9; $i++) { $f = ''; if ($rm.Contains([string]$i)) { $f = [string]$rm[[string]$i] }; [void]$r.Add($f) }
        $perm['r'] = $r
        # 1.6.1: einzelne Spieler (NexLoot 0.26): u = { Name = Rechte }, zusaetzlich zum Rang
        $um = ConvertTo-NexMap (Get-NexField $p 'u')
        if ($um.Count -gt 0) {
            $uo = New-Object System.Collections.Specialized.OrderedDictionary
            foreach ($n in (Get-NexSortedKeys $um)) { if ([string]$n -ne '' -and [string]$um[$n] -cmatch '^[A-Z]{1,12}$') { $uo[[string]$n] = [string]$um[$n] } }
            if ($uo.Count -gt 0) { $perm['u'] = $uo }
        }
        $st['perm'] = $perm
    } else { $st['perm'] = $null }
    $items = New-Object System.Collections.Specialized.OrderedDictionary
    $im = ConvertTo-NexMap (Get-NexField $db 'items')
    foreach ($k in $im.Keys) {
        $it = $im[$k]
        if ($k -eq '_decay' -and $it -is [System.Collections.IDictionary]) {
            # 1.6: Merker "Verfall bei Discord gepostet" (steht bei den Item-Namen, damit es keine neue Datenbank-Funktion braucht)
            $y = New-Object System.Collections.Specialized.OrderedDictionary
            $y['dp'] = Get-NexLong (Get-NexField $it 'dp')
            $v = Get-NexField $it 'by'; if ($null -ne $v) { $y['by'] = [string]$v }
            # wer gerade postet (reserviert): c = Name, ct = seit wann, v = welcher Verfall
            $v = Get-NexField $it 'c'; if ($null -ne $v -and [string]$v -ne '') { $y['c'] = [string]$v; $y['ct'] = Get-NexLong (Get-NexField $it 'ct'); $y['v'] = Get-NexLong (Get-NexField $it 'v') }
            $items[$k] = $y
        } elseif ($it -is [System.Collections.IDictionary]) {
            $y = New-Object System.Collections.Specialized.OrderedDictionary
            $v = Get-NexField $it 'n'; if ($null -ne $v) { $y['n'] = [string]$v }
            $v = Get-NexField $it 'q'; if ($null -ne $v) { $y['q'] = Get-NexLong $v }
            $items[$k] = $y
        }
    }
    $st['items'] = $items
    $classes = New-Object System.Collections.Specialized.OrderedDictionary
    $cm = ConvertTo-NexMap (Get-NexField $db 'classes')
    foreach ($k in $cm.Keys) { if ($cm[$k] -is [string]) { $classes[$k] = $cm[$k] } }
    $st['classes'] = $classes
    # Namen und Farben der Auswahl-Knoepfe (ab NexLoot 0.25): { rev, at, by, l = { KEY = Name }, c = { KEY = rrggbb } }
    $st['choices'] = $null
    $ch = Get-NexField $db 'choices'
    if ($ch -is [System.Collections.IDictionary] -and $null -ne (Get-NexField $ch 'rev')) {
        $co = New-Object System.Collections.Specialized.OrderedDictionary
        $co['rev'] = Get-NexLong (Get-NexField $ch 'rev')
        $co['at'] = Get-NexLong (Get-NexField $ch 'at')
        $co['by'] = [string](Get-NexField $ch 'by')
        $lo = New-Object System.Collections.Specialized.OrderedDictionary
        $lm = ConvertTo-NexMap (Get-NexField $ch 'l')
        foreach ($k in (Get-NexSortedKeys $lm)) { if ([string]$k -match '^[A-Z]+$' -and $lm[$k] -is [string] -and $lm[$k] -ne '') { $lo[[string]$k] = [string]$lm[$k] } }
        $cc = New-Object System.Collections.Specialized.OrderedDictionary
        $cm = ConvertTo-NexMap (Get-NexField $ch 'c')
        foreach ($k in (Get-NexSortedKeys $cm)) { if ([string]$k -match '^[A-Z]+$' -and [string]$cm[$k] -match '^[0-9a-fA-F]{6}$') { $cc[[string]$k] = ([string]$cm[$k]).ToLowerInvariant() } }
        $co['l'] = $lo
        $co['c'] = $cc
        $st['choices'] = $co
    }
    return $st
}

function Get-NexHistKey($h) {
    return ('{0}|{1}|{2}|{3}|{4}' -f $h['t'], $h['name'], $h['id'], $h['cost'], $h['key'])
}

function Get-NexHistSet($st) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($null -ne $st) { foreach ($h in $st['history']) { [void]$set.Add((Get-NexHistKey $h)) } }
    return , $set
}

# Inhalt, der ueber die Stand-Nummer abgeglichen wird: Coins, Historie, Verfall
function Get-NexCoreJson($st) {
    $keys = New-Object 'System.Collections.Generic.List[string]'
    foreach ($h in $st['history']) { $keys.Add((Get-NexHistKey $h)) }
    $keys.Sort([StringComparer]::Ordinal)
    $core = New-Object System.Collections.Specialized.OrderedDictionary
    $core['coins'] = $st['coins']
    $core['history'] = $keys
    $core['lastDecay'] = $st['lastDecay']
    return ConvertTo-NexJson $core
}
function Get-NexCoreHash($st) { return Get-NexSha256 (Get-NexCoreJson $st) }

# Basis fuer den naechsten Abgleich: was Spiel und Webapp zuletzt gemeinsam hatten
function Get-NexBase($st) {
    $b = New-Object System.Collections.Specialized.OrderedDictionary
    $b['rev'] = $st['rev']
    $b['hash'] = Get-NexCoreHash $st
    $keys = New-Object System.Collections.ArrayList
    foreach ($h in $st['history']) { [void]$keys.Add((Get-NexHistKey $h)) }
    $b['hist'] = $keys
    $b['coins'] = $st['coins']
    $b['lastDecay'] = $st['lastDecay']
    return $b
}

# ---------------------------------------------------------------------------------------------
# Zusammenfuehren von Sessions, Rechten, Item-Namen, Klassen (die laufen nicht ueber die Stand-Nummer)
# ---------------------------------------------------------------------------------------------
function Merge-NexSessions($a, $b) {
    $byKey = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($src in @($b, $a)) {
        if ($null -eq $src) { continue }
        foreach ($e in $src) {
            $k = [string]$e['host'] + '|' + [string]$e['sid']
            if (-not $byKey.Contains($k)) { $byKey[$k] = $e; continue }
            $o = $byKey[$k]
            $n = New-Object System.Collections.Specialized.OrderedDictionary
            $newer = $e
            $older = $o
            if ((Get-NexLong $o['at']) -gt (Get-NexLong $e['at'])) { $newer = $o; $older = $e }
            foreach ($f in @('sid', 'host', 'start', 'stop', 'name', 'at')) {
                if ($newer.Contains($f)) { $n[$f] = $newer[$f] } elseif ($older.Contains($f) -and $f -ne 'stop') { $n[$f] = $older[$f] }
            }
            if ($o.Contains('start') -and $e.Contains('start')) { $n['start'] = [math]::Min((Get-NexLong $o['start']), (Get-NexLong $e['start'])) }
            $ia = $o['items']; $ib = $e['items']
            $ca = 0; if ($null -ne $ia) { $ca = @($ia | Where-Object { $_ -and $_.Contains('w') }).Count }
            $cb = 0; if ($null -ne $ib) { $cb = @($ib | Where-Object { $_ -and $_.Contains('w') }).Count }
            # mehr Gewinner gewinnt; bei Gleichstand die laengere Liste, sonst der neuere Stand (1.6: Korrekturen im Rueckblick)
            $useB = ($cb -gt $ca -or ($cb -eq $ca -and @($ib).Count -gt @($ia).Count) -or ($cb -eq $ca -and @($ib).Count -eq @($ia).Count -and [object]::ReferenceEquals($newer, $e) -and (Get-NexLong $e['at']) -gt (Get-NexLong $o['at'])))
            if ($useB) { $n['items'] = $ib; $other = $ia } else { $n['items'] = $ia; $other = $ib }
            # 1.6: Antworten/Wuerfe vom anderen Stand ergaenzen (gleiche Stelle, gleiches Item)
            if ($null -ne $n['items'] -and $null -ne $other) {
                $ol = @($other)
                $i2 = 0
                foreach ($x2 in @($n['items'])) {
                    if ($i2 -lt $ol.Count -and $x2 -is [System.Collections.IDictionary] -and $ol[$i2] -is [System.Collections.IDictionary] -and
                        -not $x2.Contains('a') -and $ol[$i2].Contains('a') -and (Get-NexLong $x2['id']) -eq (Get-NexLong $ol[$i2]['id']) -and [string]$x2['w'] -eq [string]$ol[$i2]['w']) {
                        foreach ($f2 in @('a', 'ro', 'nt')) { if ($ol[$i2].Contains($f2)) { $x2[$f2] = $ol[$i2][$f2] } }
                    }
                    $i2++
                }
            }
            # Teilnehmer aus beiden zusammen, "nach Discord gepostet" bleibt erhalten
            $all = New-Object System.Collections.ArrayList
            foreach ($src2 in @($o['members'], $e['members'])) { if ($null -ne $src2) { foreach ($x in $src2) { [void]$all.Add($x) } } }
            $mem = Get-NexNames $all
            if ($mem.Count -gt 0) { $n['members'] = $mem }
            $dp = [math]::Max((Get-NexLong $o['dp']), (Get-NexLong $e['dp']))
            if ($dp -gt 0) { $n['dp'] = $dp }
            # 1.5: was gepostet wurde - vom Eintrag mit dem neueren Merker
            $dps = $null
            if ((Get-NexLong $o['dp']) -ge (Get-NexLong $e['dp'])) { $dps = $o['dps']; if ($null -eq $dps) { $dps = $e['dps'] } }
            else { $dps = $e['dps']; if ($null -eq $dps) { $dps = $o['dps'] } }
            if ($null -ne $dps) { $n['dps'] = $dps }
            $byKey[$k] = $n
        }
    }
    $list = New-Object System.Collections.ArrayList
    foreach ($k in $byKey.Keys) { [void]$list.Add($byKey[$k]) }
    $sorted = New-Object System.Collections.ArrayList
    foreach ($e in ($list | Sort-Object { $s = Get-NexLong $_['start']; if ($s -eq 0) { $s = Get-NexLong $_['sid'] }; $s })) { [void]$sorted.Add($e) }
    while ($sorted.Count -gt 300) { $sorted.RemoveAt(0) }
    return , $sorted
}

function Merge-NexWipes($a, $b) {
    $byKey = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($src in @($a, $b)) {
        if ($null -eq $src) { continue }
        foreach ($m in $src) {
            $k = '{0}|{1}|{2}|{3}' -f $m['at'], $m['from'], $m['to'], $m['what']
            if (-not $byKey.Contains($k)) { $byKey[$k] = $m }
        }
    }
    $list = New-Object System.Collections.ArrayList
    foreach ($m in ($byKey.Values | Sort-Object { Get-NexLong $_['at'] })) { [void]$list.Add($m) }
    while ($list.Count -gt 20) { $list.RemoveAt(0) }
    return , $list
}

# Session von einem Wipe erfasst? (Start im Bereich, seit dem Wipe nicht mehr geaendert - wie im Addon)
function Test-NexSessWiped($e, $wipes) {
    $st = Get-NexLong $e['start']
    if ($st -le 0) { $st = Get-NexLong $e['sid'] }
    $at = $st
    if ($e.Contains('at')) { $at = Get-NexLong $e['at'] }
    foreach ($m in $wipes) {
        if (([string]$m['what']).Contains('S') -and $st -ge (Get-NexLong $m['from']) -and $st -le (Get-NexLong $m['to']) -and $at -le (Get-NexLong $m['at'])) { return $true }
    }
    return $false
}
function Select-NexSessions($sess, $wipes) {
    $out = New-Object System.Collections.ArrayList
    foreach ($e in $sess) { if (-not (Test-NexSessWiped $e $wipes)) { [void]$out.Add($e) } }
    return , $out
}

function Merge-NexMaps($a, $b) {
    # a hat Vorrang
    $m = New-Object System.Collections.Specialized.OrderedDictionary
    if ($null -ne $b) { foreach ($k in $b.Keys) { $m[$k] = $b[$k] } }
    if ($null -ne $a) { foreach ($k in $a.Keys) { $m[$k] = $a[$k] } }
    return $m
}

function Merge-NexPerm($a, $b) {
    if ($null -eq $a) { return $b }
    if ($null -eq $b) { return $a }
    if ((Get-NexLong $b['rev']) -gt (Get-NexLong $a['rev'])) { return $b }
    return $a
}

# Neuer Stand: Kern (Coins/Historie/Verfall) von $core, Rest aus beiden zusammengefuehrt
function New-NexTarget($core, [long] $rev, $L, $W) {
    $t = New-Object System.Collections.Specialized.OrderedDictionary
    $t['rev'] = $rev
    $t['coins'] = $core['coins']
    $t['history'] = $core['history']
    $t['lastDecay'] = $core['lastDecay']
    $sl = $null; $sw = $null; $pl = $null; $pw = $null; $il = $null; $iw = $null; $cl = $null; $cw = $null; $wl = $null; $ww = $null
    if ($null -ne $L) { $sl = $L['sessions']; $pl = $L['perm']; $il = $L['items']; $cl = $L['classes']; $wl = $L['wipes'] }
    if ($null -ne $W) { $sw = $W['sessions']; $pw = $W['perm']; $iw = $W['items']; $cw = $W['classes']; $ww = $W['wipes'] }
    $t['wipes'] = Merge-NexWipes $wl $ww
    $t['sessions'] = Select-NexSessions (Merge-NexSessions $sl $sw) $t['wipes']
    $t['perm'] = Merge-NexPerm $pl $pw
    $t['items'] = Merge-NexMaps $il $iw
    # 1.6: Merker "Verfall gepostet" kommt nur aus der Webapp (nie aus dem Spiel)
    if ($t['items'].Contains('_decay')) { $t['items'].Remove('_decay') }
    if ($null -ne $iw -and $iw.Contains('_decay')) { $t['items']['_decay'] = $iw['_decay'] }
    $t['classes'] = Merge-NexMaps $cl $cw
    $chl = $null; $chw = $null
    if ($null -ne $L) { $chl = $L['choices'] }
    if ($null -ne $W) { $chw = $W['choices'] }
    $t['choices'] = Merge-NexPerm $chl $chw # (neuerer Stand gewinnt, wie bei den Rechten)
    return $t
}

# ---------------------------------------------------------------------------------------------
# Verfall aus der Datenbank (ab 1.4): die Datenbank zieht jeden Mittwoch 5:30 die Prozente ab und traegt
# "Verfall" (Name *, Grund "-10%" bzw. "-10% (3 Wochen)") in die Historie ein.
# ---------------------------------------------------------------------------------------------
function Get-NexDecayInfo([string] $Why) {
    if ($Why -match '^-(\d+)%(?: \((\d+) Wochen\))?$') {
        $wk = 1
        if ($Matches[2]) { $wk = [int]$Matches[2] }
        return , @([int]$Matches[1], $wk)
    }
    return $null
}

# Coins nach dem Verfall (abgerundet, Minus und 0 bleiben)
function Get-NexDecayed($Coins, [int] $Pct, [int] $Weeks) {
    $res = New-Object System.Collections.Specialized.OrderedDictionary
    $src = ConvertTo-NexMap $Coins
    foreach ($k in $src.Keys) {
        $val = Get-NexLong $src[$k]
        if ($val -gt 0) { for ($i = 0; $i -lt $Weeks; $i++) { $val = [long][math]::Floor(($val * (100 - $Pct)) / 100) } }
        $res[$k] = $val
    }
    return $res
}

# Eintraege zeitlich passend in die Historie einsortieren
function Add-NexHistByTime($Hist, $Extra) {
    $res = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.ArrayList
    foreach ($x in ($Extra | Sort-Object { Get-NexLong $_['t'] })) { [void]$queue.Add($x) }
    foreach ($h in $Hist) {
        while ($queue.Count -gt 0 -and (Get-NexLong $queue[0]['t']) -lt (Get-NexLong $h['t'])) { [void]$res.Add($queue[0]); $queue.RemoveAt(0) }
        [void]$res.Add($h)
    }
    foreach ($x in $queue) { [void]$res.Add($x) }
    return , $res
}

# Hat die Webapp seit dem letzten Abgleich NUR den Verfall der Datenbank dazubekommen?
# Ja: Liste @{ Entry; Pct; Weeks } der neuen Verfall-Eintraege. Nein: $null
function Get-NexWebDecayOnly($W, $B, $AddedW, $RemovedW) {
    if ($null -eq $W -or $null -eq $B -or $null -eq $B['coins']) { return $null }
    if (@($RemovedW).Count -gt 0 -or @($AddedW).Count -eq 0) { return $null }
    $added = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in $AddedW) { [void]$added.Add([string]$k) }
    $found = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $expect = ConvertTo-NexMap $B['coins']
    foreach ($h in $W['history']) {
        $hk = Get-NexHistKey $h
        if (-not $added.Contains($hk) -or -not $seen.Add($hk)) { continue }
        if ([string]$h['key'] -ne 'V' -or [string]$h['name'] -ne '*') { return $null }
        $info = Get-NexDecayInfo ([string]$h['why'])
        if ($null -eq $info) { return $null }
        $expect = Get-NexDecayed $expect $info[0] $info[1]
        [void]$found.Add(@{ Entry = $h; Pct = $info[0]; Weeks = $info[1] })
    }
    if ($found.Count -ne $added.Count) { return $null }
    # Coins der Webapp muessen genau "Stand vom letzten Abgleich minus Verfall" sein
    $wc = ConvertTo-NexMap $W['coins']
    if ($wc.Count -ne $expect.Count) { return $null }
    foreach ($k in $expect.Keys) {
        if (-not $wc.Contains($k) -or (Get-NexLong $wc[$k]) -ne (Get-NexLong $expect[$k])) { return $null }
    }
    if ((Get-NexLong $W['lastDecay']) -le (Get-NexLong $B['lastDecay'])) { return $null }
    return , $found
}

# ---------------------------------------------------------------------------------------------
# Entscheidung: wer hat den neueren Stand?
#   L = Stand im Spiel (SavedVariables), W = Stand in der Webapp, B = gemeinsame Basis vom letzten Abgleich
# Ergebnis: Winner 'L' / 'W' / '' , Rev (neue Stand-Nummer), Push (in die Webapp), WebData (ins Addon schreiben),
#           Conflict + Lost (eigene Aenderungen, die der Webapp-Stand ueberschreibt)
# ---------------------------------------------------------------------------------------------
function Get-NexDecision($L, $W, $B) {
    $d = @{ Winner = ''; Rev = 0L; Push = $false; WebData = $false; Conflict = $false; Reason = ''; LostHist = @(); LostCoins = @()
        Core = $null; Decay = $false }
    if ($null -eq $L -and $null -eq $W) { $d.Reason = 'keine Daten'; return $d }
    if ($null -eq $W) { $d.Winner = 'L'; $d.Rev = [math]::Max(1L, [long]$L['rev']); $d.Push = $true; $d.Reason = 'erster Upload'; return $d }
    if ($null -eq $L) { $d.Winner = 'W'; $d.Rev = [long]$W['rev']; $d.WebData = $true; $d.Reason = 'noch keine Daten im Spiel'; return $d }
    $lr = [long]$L['rev']; $wr = [long]$W['rev']
    if ((Get-NexCoreHash $L) -eq (Get-NexCoreHash $W)) {
        if ($lr -gt $wr) { $d.Winner = 'L'; $d.Rev = $lr; $d.Push = $true; $d.Reason = 'gleicher Inhalt, neuere Stand-Nummer im Spiel' }
        elseif ($wr -gt $lr) { $d.Winner = 'W'; $d.Rev = $wr; $d.WebData = $true; $d.Reason = 'gleicher Inhalt, neuere Stand-Nummer in der Webapp' }
        else { $d.Winner = ''; $d.Rev = $lr; $d.Reason = 'gleich' }
        return $d
    }
    $Ls = Get-NexHistSet $L; $Ws = Get-NexHistSet $W
    $Bs = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($null -ne $B) { foreach ($k in $B['hist']) { [void]$Bs.Add([string]$k) } }
    $addedL = @(); $addedW = @(); $removedL = @(); $removedW = @()
    foreach ($k in $Ls) { if (-not $Bs.Contains($k)) { $addedL += $k } }
    foreach ($k in $Ws) { if (-not $Bs.Contains($k)) { $addedW += $k } }
    foreach ($k in $Bs) { if (-not $Ls.Contains($k)) { $removedL += $k }; if (-not $Ws.Contains($k)) { $removedW += $k } }
    $LcW = ([long]$L['lastDecay'] -ge [long]$W['lastDecay'])
    foreach ($k in $addedW) { if (-not $Ls.Contains($k)) { $LcW = $false; break } }
    foreach ($k in $removedW) { if ($Ls.Contains($k)) { $LcW = $false; break } }
    $WcL = ([long]$W['lastDecay'] -ge [long]$L['lastDecay'])
    foreach ($k in $addedL) { if (-not $Ws.Contains($k)) { $WcL = $false; break } }
    foreach ($k in $removedL) { if ($Ws.Contains($k)) { $WcL = $false; break } }
    $win = ''
    if ($LcW -and -not $WcL) { $win = 'L'; $d.Reason = 'Spiel hat alles aus der Webapp und mehr' }
    elseif ($WcL -and -not $LcW) { $win = 'W'; $d.Reason = 'Webapp hat alles aus dem Spiel und mehr' }
    elseif ($LcW -and $WcL) {
        if ($lr -gt $wr) { $win = 'L'; $d.Reason = 'nur Coins geaendert, Spiel neuer' }
        elseif ($wr -gt $lr) { $win = 'W'; $d.Reason = 'nur Coins geaendert, Webapp neuer' }
    }
    if ($win -eq 'L') {
        $d.Winner = 'L'; $d.Push = $true
        if ($lr -gt $wr) { $d.Rev = $lr } else { $d.Rev = $wr + 1; $d.WebData = $true }
        return $d
    }
    if ($win -eq 'W') {
        $d.Winner = 'W'; $d.WebData = $true
        if ($wr -gt $lr) { $d.Rev = $wr } else { $d.Rev = $lr + 1; $d.Push = $true }
        return $d
    }
    # 1.4: In der Webapp ist seit dem letzten Abgleich nur der Verfall der Datenbank dazugekommen, im Spiel
    # aber eigene Eintraege (z. B. Raid noch nicht hochgeladen). Dann kein Konflikt: der Verfall wird auf den
    # Stand im Spiel angewendet, nichts geht verloren.
    $dec = Get-NexWebDecayOnly $W $B $addedW $removedW
    if ($null -ne $dec) {
        $ownDecay = $false
        foreach ($h in $L['history']) { if ([string]$h['key'] -eq 'V' -and -not $Bs.Contains((Get-NexHistKey $h))) { $ownDecay = $true; break } }
        $core = New-Object System.Collections.Specialized.OrderedDictionary
        if ($ownDecay) {
            # Das Spiel hat den Verfall schon selbst gemacht (altes Addon): nicht doppelt abziehen
            $core['coins'] = $L['coins']
            $core['history'] = $L['history']
            $d.Reason = 'Verfall schon im Spiel gemacht - Verfall der Datenbank nicht doppelt'
        } else {
            $nc = $L['coins']
            $extra = New-Object System.Collections.ArrayList
            foreach ($x in $dec) { $nc = Get-NexDecayed $nc $x.Pct $x.Weeks; [void]$extra.Add($x.Entry) }
            $core['coins'] = $nc
            $core['history'] = Add-NexHistByTime $L['history'] $extra
            $d.Decay = $true
            $d.Reason = 'Verfall aus der Datenbank auf den Stand im Spiel angewendet'
        }
        $core['lastDecay'] = [math]::Max([long]$L['lastDecay'], [long]$W['lastDecay'])
        $d.Core = $core; $d.Winner = 'L'; $d.Push = $true; $d.WebData = $true
        $d.Rev = [math]::Max($lr, $wr) + 1
        return $d
    }
    # Konflikt: beide Seiten haben unabhaengig voneinander geaendert. Der Webapp-Stand gilt fuer alle,
    # die eigenen Aenderungen werden im Bericht aufgelistet.
    $d.Conflict = $true; $d.Winner = 'W'; $d.Push = $true; $d.WebData = $true
    $d.Rev = [math]::Max($lr, $wr) + 1
    $d.Reason = 'Konflikt'
    $lost = @()
    foreach ($h in $L['history']) { $k = Get-NexHistKey $h; if (-not $Ws.Contains($k) -and -not $Bs.Contains($k)) { $lost += , $h } }
    $d.LostHist = $lost
    $lc = @()
    foreach ($n in (Get-NexSortedKeys $L['coins'])) {
        $lv = [long]$L['coins'][$n]; $wv = $null
        if ($W['coins'].Contains($n)) { $wv = [long]$W['coins'][$n] }
        if ($null -eq $wv -or $lv -ne $wv) { $lc += , @($n, $lv, $wv) }
    }
    $d.LostCoins = $lc
    return $d
}

# ---------------------------------------------------------------------------------------------
# Supabase (REST)
# ---------------------------------------------------------------------------------------------
function Get-NexHeaders($cfg) {
    $h = @{ apikey = $cfg.key; Accept = 'application/json' }
    if ($cfg.key -like 'eyJ*') { $h['Authorization'] = 'Bearer ' + $cfg.key }
    return $h
}

function Get-NexErrorText($err) {
    $msg = ''
    try { if ($err.ErrorDetails -and $err.ErrorDetails.Message) { $msg = $err.ErrorDetails.Message } } catch { }
    if (-not $msg) { $msg = $err.Exception.Message }
    try { $j = ConvertFrom-NexJson $msg; if ($j -is [System.Collections.IDictionary] -and $j.Contains('message')) { $msg = [string]$j['message'] } } catch { }
    return $msg
}

function Invoke-NexHttp($cfg, [string] $Method, [string] $Path, $BodyObj) {
    $url = $cfg.url.TrimEnd('/') + $Path
    $params = @{ Uri = $url; Method = $Method; Headers = (Get-NexHeaders $cfg); TimeoutSec = 25; UseBasicParsing = $true }
    if ($null -ne $BodyObj) {
        $params['Body'] = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-NexJson $BodyObj))
        $params['ContentType'] = 'application/json; charset=utf-8'
    }
    try {
        $resp = Invoke-WebRequest @params
    } catch {
        throw (Get-NexErrorText $_)
    }
    $content = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    return ConvertFrom-NexJson $content
}

function Get-NexWeb($cfg) {
    $g = [uri]::EscapeDataString($cfg.guild)
    $rows = Invoke-NexHttp $cfg 'GET' "/rest/v1/nexloot_state?guild=eq.$g&select=rev,data,updated_at,updated_by" $null
    if ($null -eq $rows -or $rows.Count -eq 0) { return $null }
    $row = $rows[0]
    $st = ConvertTo-NexState $row['data'] (Get-NexLong $row['rev'])
    if ($null -ne $st) { $st['_updated_at'] = $row['updated_at']; $st['_updated_by'] = $row['updated_by'] }
    return $st
}

function Push-NexWeb($cfg, $target) {
    $data = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($k in $target.Keys) { if (-not ([string]$k).StartsWith('_')) { $data[$k] = $target[$k] } }
    $body = [ordered]@{ p_guild = $cfg.guild; p_rev = [long]$target['rev']; p_data = $data; p_by = $cfg.name; p_secret = $cfg.password }
    return Invoke-NexHttp $cfg 'POST' '/rest/v1/rpc/nexloot_push' $body
}

function Push-NexExtras($cfg, $items, $classes, $sessions) {
    $body = [ordered]@{ p_guild = $cfg.guild; p_items = $items; p_classes = $classes; p_sessions = $sessions; p_secret = $cfg.password }
    return Invoke-NexHttp $cfg 'POST' '/rest/v1/rpc/nexloot_extras' $body
}

# ---------------------------------------------------------------------------------------------
# Dateien
# ---------------------------------------------------------------------------------------------
$script:NexUtf8 = New-Object System.Text.UTF8Encoding($false)

function Read-NexSV([string] $Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path, $script:NexUtf8)
    $db = ConvertFrom-NexLua $text 'NexLootDB'
    if ($null -eq $db) { return $null }
    return ConvertTo-NexState $db
}

function Write-NexFileAtomic([string] $Path, [string] $Text) {
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Text, $script:NexUtf8)
    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Copy($tmp, $Path, $true); [System.IO.File]::Delete($tmp) }
    else { [System.IO.File]::Move($tmp, $Path) }
}

# WebData.lua: das liest das Addon beim Laden (nach Login oder /reload)
function Write-NexWebData([string] $Path, $target, $baseRev, [long] $checkedAt) {
    $w = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($k in @('rev', 'coins', 'history', 'lastDecay', 'perm', 'wipes', 'choices')) { $w[$k] = $target[$k] }
    $sl = New-Object System.Collections.ArrayList # Sessions ohne Teilnehmer/Discord-Merker (braucht das Addon nicht)
    foreach ($e in $target['sessions']) {
        $x = New-Object System.Collections.Specialized.OrderedDictionary
        foreach ($k in $e.Keys) { if ($k -ne 'members' -and $k -ne 'dp' -and $k -ne 'dps') { $x[$k] = $e[$k] } }
        if ($null -ne $e['items']) {
            # 1.6: Antworten/Wuerfe/Notizen nur fuer die Webapp - das Addon hat sie selbst (haelt WebData.lua klein)
            $il2 = New-Object System.Collections.ArrayList
            foreach ($it in $e['items']) {
                if (-not ($it -is [System.Collections.IDictionary])) { [void]$il2.Add($it); continue }
                $y = New-Object System.Collections.Specialized.OrderedDictionary
                foreach ($k in $it.Keys) { if ($k -ne 'a' -and $k -ne 'ro' -and $k -ne 'nt') { $y[$k] = $it[$k] } }
                [void]$il2.Add($y)
            }
            $x['items'] = $il2
        }
        [void]$sl.Add($x)
    }
    $w['sessions'] = $sl
    if ($null -ne $baseRev) { $w['baseRev'] = [long]$baseRev }
    $w['checkedAt'] = $checkedAt
    $text = "-- NexLoot: Stand aus der Webapp. Geschrieben von der NexLoot-Companion-App am " +
        [DateTime]::Now.ToString('dd.MM.yyyy HH:mm:ss', $script:NexInv) + ".`n-- Nicht von Hand bearbeiten.`nNexLootWebData = " +
        (ConvertTo-NexLua $w) + "`n"
    Write-NexFileAtomic $Path $text
}

function Get-NexUnixNow() { return [long][math]::Floor(([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds) }

function Format-NexConflictReport($d, $L, $W, $items) {
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('NexLoot Companion - Konflikt beim Abgleich (' + [DateTime]::Now.ToString('dd.MM.yyyy HH:mm', $script:NexInv) + ')')
    [void]$lines.Add('')
    [void]$lines.Add('Im Spiel und in der Webapp wurde unabhängig voneinander etwas geändert (z. B. zwei Raids,')
    [void]$lines.Add('ohne dass sich die Offiziere dazwischen im Spiel gesehen haben).')
    [void]$lines.Add('Damit alle wieder denselben Stand haben, gilt jetzt der Stand aus der Webapp (Stand ' + $d.Rev + ').')
    [void]$lines.Add('Er wird beim nächsten Einloggen bzw. /reload übernommen.')
    [void]$lines.Add('')
    [void]$lines.Add('Diese Änderungen aus DEINEM Spiel sind im Webapp-Stand nicht enthalten – bitte prüfen und')
    [void]$lines.Add('bei Bedarf im Spiel neu eintragen (/nex history add ... bzw. /nex coins ...):')
    [void]$lines.Add('')
    if (@($d.LostHist).Count -gt 0) {
        [void]$lines.Add('Einträge (Items und Coin-Änderungen):')
        $coinKeys = @{ 'C' = 'Coins geändert'; 'CG' = 'Coins für die Gruppe'; 'V' = 'Verfall'; 'CD' = 'aus der Datenbank gelöscht' }
        $lootKeys = @{ 'UPC' = 'Upgrade + Coins'; 'UP' = 'Upgrade'; 'ROS' = 'Raid OS'; 'OS' = 'OS/PvP'; 'PASS' = 'Passen';
            'MAN' = 'Von Hand'; 'DE' = 'Zum Entzaubern'; 'AUTO' = 'Automatisch' }
        foreach ($h in $d.LostHist) {
            $when = ([DateTime]'1970-01-01').AddSeconds([double]$h['t']).ToLocalTime().ToString('dd.MM. HH:mm', $script:NexInv)
            $why = ''
            if ($h.Contains('why')) { $why = '  Grund: ' + $h['why'] }
            if ($coinKeys.ContainsKey([string]$h['key'])) {
                $delta = -1 * [long]$h['cost']
                $sign = ''; if ($delta -gt 0) { $sign = '+' }
                [void]$lines.Add(('  {0}  {1}: {2} ({3}{4} Coins){5}' -f $when, $h['name'], $coinKeys[[string]$h['key']], $sign, $delta, $why))
                continue
            }
            $iname = 'Item ' + $h['id']
            if ($null -ne $items -and $items.Contains([string]$h['id'])) { $iname = $items[[string]$h['id']]['n'] }
            $label = [string]$h['key']
            if ($lootKeys.ContainsKey($label)) { $label = $lootKeys[$label] }
            [void]$lines.Add(('  {0}  {1}  ->  {2}  ({3}, {4} Coins)' -f $when, $iname, $h['name'], $label, $h['cost']))
        }
        [void]$lines.Add('')
    }
    if (@($d.LostCoins).Count -gt 0) {
        [void]$lines.Add('Coins, die abweichen (dein Spiel / Webapp):')
        foreach ($c in $d.LostCoins) {
            $b = 'nicht vorhanden'; if ($null -ne $c[2]) { $b = [string]$c[2] }
            [void]$lines.Add(('  {0}: {1} / {2}' -f $c[0], $c[1], $b))
        }
        [void]$lines.Add('')
    }
    [void]$lines.Add('Alle Stände sind zusätzlich in Supabase gesichert (Tabelle nexloot_snapshots).')
    return ($lines -join "`r`n")
}

# ---------------------------------------------------------------------------------------------
# Ein Abgleich. $ctx: @{ cfg; state (persistenter Zustand); dataDir }
# Rueckgabe: @{ Action; Message; Notify; Conflict; ReportPath; WebRev; LocalRev }
# ---------------------------------------------------------------------------------------------
function Invoke-NexSync($ctx) {
    $cfg = $ctx.cfg
    $state = $ctx.state
    $res = @{ Action = 'none'; Message = ''; Notify = $false; Conflict = $false; ReportPath = $null; WebRev = $null; LocalRev = $null; Target = $null; Web = $null }
    $L = $null
    try { $L = Read-NexSV $cfg.svPath } catch {
        $res.Action = 'svError'; $res.Message = 'WoW-Daten gerade nicht lesbar (WoW speichert noch?): ' + $_.Exception.Message
        return $res
    }
    $W = Get-NexWeb $cfg
    if ($null -ne $L) { $res.LocalRev = [long]$L['rev'] }
    if ($null -ne $W) { $res.WebRev = [long]$W['rev'] }
    $B = $null
    if ($state.Contains('base')) { $B = $state['base'] }
    $d = Get-NexDecision $L $W $B
    $now = Get-NexUnixNow
    $target = $null
    if ($null -ne $d.Core) { $target = New-NexTarget $d.Core $d.Rev $L $W }
    elseif ($d.Winner -eq 'L') { $target = New-NexTarget $L $d.Rev $L $W }
    elseif ($d.Winner -eq 'W') { $target = New-NexTarget $W $d.Rev $L $W }
    elseif ($null -ne $L) { $target = New-NexTarget $L $d.Rev $L $W }

    if ($d.Push -and $null -ne $target) {
        $r = Push-NexWeb $cfg $target
        if (-not $r['ok']) {
            $res.Action = 'retry'; $res.Message = 'Webapp hat inzwischen einen neueren Stand (' + $r['rev'] + ') – neuer Versuch gleich.'
            return $res
        }
        $res.WebRev = [long]$r['rev']
    } elseif ($null -ne $W -and $null -ne $target) {
        # Item-Namen, Klassen, Sessions ergaenzen, wenn das Spiel mehr weiss als die Webapp
        $needItems = $false; $needClasses = $false
        foreach ($k in $target['items'].Keys) { if (-not ([string]$k).StartsWith('_') -and -not $W['items'].Contains($k)) { $needItems = $true; break } }
        foreach ($k in $target['classes'].Keys) { if (-not $W['classes'].Contains($k) -or $W['classes'][$k] -ne $target['classes'][$k]) { $needClasses = $true; break } }
        $needSess = (ConvertTo-NexJson $target['sessions']) -ne (ConvertTo-NexJson $W['sessions'])
        if ($needItems -or $needClasses -or $needSess) {
            $s = $null; if ($needSess) { $s = $target['sessions'] }
            $io = New-Object System.Collections.Specialized.OrderedDictionary # ohne Merker (_decay): den schreibt nur der Discord-Teil
            foreach ($k in $target['items'].Keys) { if (-not ([string]$k).StartsWith('_')) { $io[$k] = $target['items'][$k] } }
            [void](Push-NexExtras $cfg $io $target['classes'] $s)
        }
    }

    if ($null -ne $target -and $cfg.addonPath) {
        $wdPath = Join-Path $cfg.addonPath 'WebData.lua'
        $h = Get-NexSha256 ((ConvertTo-NexJson $target['rev']) + (Get-NexCoreJson $target) + (ConvertTo-NexJson $target['perm']) + (ConvertTo-NexJson $target['sessions']) + (ConvertTo-NexJson $target['wipes']))
        $baseRev = $null; if ($null -ne $L) { $baseRev = [long]$L['rev'] }
        $last = $null; if ($state.Contains('webData')) { $last = $state['webData'] }
        $stale = ($null -eq $last) -or ($last['hash'] -ne $h) -or ((Get-NexLong $last['baseRev'] (-1)) -ne (Get-NexLong $baseRev (-1))) -or ($now - (Get-NexLong $last['at']) -ge 1200) -or -not (Test-Path -LiteralPath $wdPath)
        if ($stale -and (Test-Path -LiteralPath $cfg.addonPath)) {
            Write-NexWebData $wdPath $target $baseRev $now
            $state['webData'] = [ordered]@{ hash = $h; rev = [long]$target['rev']; baseRev = $baseRev; at = $now }
        }
    }

    if ($d.Conflict) {
        $report = Format-NexConflictReport $d $L $W $target['items']
        $p = Join-Path $ctx.dataDir ('Konflikt-' + [DateTime]::Now.ToString('yyyy-MM-dd-HHmm', $script:NexInv) + '.txt')
        [System.IO.File]::WriteAllText($p, $report, $script:NexUtf8)
        $res.Conflict = $true; $res.ReportPath = $p; $res.Notify = $true
        $res.Action = 'conflict'
        $res.Message = 'Konflikt: Spiel und Webapp wurden getrennt geändert. Es gilt der Webapp-Stand – deine abweichenden Einträge stehen im Bericht.'
    } elseif ($null -ne $d.Core) {
        $res.Action = 'decay'
        if ($d.Decay) { $res.Message = 'Coin-Verfall aus der Datenbank auf deinen Spielstand angewendet (Stand ' + $d.Rev + ').' }
        else { $res.Message = 'Verfall war im Spiel schon gemacht - nicht doppelt abgezogen (Stand ' + $d.Rev + ').' }
        $res.Notify = $true
        $state['notifiedPull'] = $d.Rev # nicht gleich noch einmal als "neuer Stand" melden
    } elseif ($d.Winner -eq 'L' -and $d.Push) {
        $res.Action = 'push'; $res.Message = 'Stand ' + $d.Rev + ' in die Webapp hochgeladen.'
        if ($d.WebData) { $res.Message += ' (Im Spiel /reload, damit die Stand-Nummer passt.)' }
    } elseif ($d.Winner -eq 'W' -and $d.WebData) {
        $res.Action = 'pull'
        $res.Message = 'Neuer Stand ' + $d.Rev + ' aus der Webapp – wird beim nächsten Einloggen bzw. /reload im Spiel übernommen.'
        $lastPull = 0L; if ($state.Contains('notifiedPull')) { $lastPull = Get-NexLong $state['notifiedPull'] }
        if ($lastPull -ne $d.Rev) { $res.Notify = $true; $state['notifiedPull'] = $d.Rev }
    } else {
        $res.Action = 'none'; $res.Message = 'Alles abgeglichen (Stand ' + $d.Rev + ').'
    }
    if ($null -ne $L) { $state['base'] = Get-NexBase $L }
    $state['lastOk'] = $now
    $res.Target = $target
    $res.Web = $W
    return $res
}

# ---------------------------------------------------------------------------------------------
# Discord (ab 1.3): nach jedem Raid eine Zusammenfassung ueber einen Webhook (kein Bot noetig).
# Die Webhook-Adresse ist geheim (wie ein Passwort): steht nur verschluesselt in config.json, nie im Protokoll.
# Wer postet? Der Companion des Raidleiters (Host der Session) sofort, alle anderen erst nach 30-40 Minuten
# (falls der Host keinen Companion mit Webhook hat). Gepostet wird pro Session einmal ("dp" in der Webapp).
# ---------------------------------------------------------------------------------------------
$script:NexKeyLabels = @{ 'UPC' = 'Nex-Coins'; 'UP' = 'Upgrade'; 'ROS' = 'Raid OS'; 'OS' = 'OS/PvP'; 'TM' = 'Transmog'; 'PASS' = 'Passen'
    'MAN' = 'Von Hand'; 'DE' = 'Entzaubern'; 'AUTO' = 'Automatisch' }
$script:NexCoinKeys = @{ 'C' = $true; 'CG' = $true; 'V' = $true; 'CD' = $true }

function Test-NexWebhookUrl([string] $Url) {
    return ($Url -match '^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_\-]+$')
}

# Text fuer Discord: Markdown-Zeichen entschaerfen, @-Erwaehnungen unschaedlich machen
function ConvertTo-NexDiscordText([string] $s) {
    if (-not $s) { return '' }
    $s = [regex]::Replace($s, '([\\*_~`|>\[\]])', '\$1')
    return $s.Replace('@', "@" + [char]0x200B)
}

function Format-NexDate([long] $t, [string] $fmt) {
    return ([DateTime]'1970-01-01').AddSeconds([double]$t).ToLocalTime().ToString($fmt, $script:NexInv)
}

# Links zu den Items: Wowhead, Bereich "Forever" (www.wowhead.com/forever/item=<ID>)
$script:NexWowhead = 'https://www.wowhead.com/forever/item='
$script:NexDays = @('So', 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa')
function Get-NexEmoji([int[]] $cp) { return (($cp | ForEach-Object { [char]::ConvertFromUtf32($_) }) -join '') }

# Discord zaehlt pro Nachricht Titel, Beschreibung, Fusszeile usw. aller Embeds (hoechstens 6000 Zeichen)
function Get-NexEmbedSize($em) {
    $n = 0
    foreach ($k in @('title', 'description')) { if ($em.Contains($k)) { $n += ([string]$em[$k]).Length } }
    if ($em.Contains('footer')) { $n += ([string]$em['footer']['text']).Length }
    return $n
}

# Zeilen auf Abschnitte verteilen (je hoechstens $Max Zeichen); eine Zeile darf selbst Zeilenumbrueche enthalten
function Split-NexLines($Lines, [int] $Max) {
    $parts = New-Object System.Collections.ArrayList
    $cur = ''
    foreach ($l in $Lines) {
        $add = [string]$l
        if ($cur -eq '') { $cur = $add }
        elseif (($cur.Length + 1 + $add.Length) -gt $Max) { [void]$parts.Add($cur); $cur = $add }
        else { $cur += "`n" + $add }
    }
    if ($cur -ne '') { [void]$parts.Add($cur) }
    return , $parts
}

# Item-Name als Link zu seiner Seite bei Wowhead (englisch, wie die Item-Namen aus dem Spiel)
# Name einer Wahl: was die Gilde eingestellt hat (NexLoot 0.25), sonst der Standard
function Get-NexKeyLabel($target, [string] $Key) {
    $ch = $null; if ($null -ne $target) { $ch = $target['choices'] }
    if ($null -ne $ch -and $null -ne $ch['l'] -and $ch['l'].Contains($Key) -and [string]$ch['l'][$Key]) { return (ConvertTo-NexDiscordText ([string]$ch['l'][$Key])) }
    if ($script:NexKeyLabels.ContainsKey($Key)) { return $script:NexKeyLabels[$Key] }
    return $Key
}

function Get-NexItemLink($items, [string] $id) {
    $info = $null; if ($null -ne $items -and $items.Contains($id)) { $info = $items[$id] }
    $name = 'Item ' + $id; if ($null -ne $info -and $info['n']) { $name = [string]$info['n'] }
    return ('[{0}]({1}{2})' -f (ConvertTo-NexDiscordText $name), $script:NexWowhead, $id)
}

# Nachrichten fuer eine Session (meist eine): oben der Raid mit Items und Raid-Punkten, darunter die Nex-Coins
# (untereinander, sortiert). Wird es fuer Discord zu lang, kommen die Coins in eine zweite Nachricht.
function New-NexDiscordMessages($target, $e, [string] $WebUrl = '') {
    $sid = Get-NexLong $e['sid']
    $items = $target['items']
    $awards = New-Object System.Collections.ArrayList
    $cg = New-Object System.Collections.ArrayList
    $delta = @{} # Coins-Aenderung in diesem Raid je Spieler
    foreach ($h in $target['history']) {
        if ((Get-NexLong $h['s']) -ne $sid) { continue }
        $k = [string]$h['key']
        $cost = Get-NexLong $h['cost']
        if ($k -eq 'CG') {
            [void]$cg.Add($h)
            foreach ($n in @($h['p'])) { if ($n) { $delta[[string]$n] = (Get-NexLong $delta[[string]$n]) - $cost } }
        } elseif ($k -eq 'C') {
            $delta[[string]$h['name']] = (Get-NexLong $delta[[string]$h['name']]) - $cost
        } elseif (-not $script:NexCoinKeys.ContainsKey($k) -and (Get-NexLong $h['id']) -gt 0) {
            [void]$awards.Add($h)
            if ($cost -ne 0) { $delta[[string]$h['name']] = (Get-NexLong $delta[[string]$h['name']]) - $cost }
        }
    }
    $arrow = Get-NexEmoji 0x21B3
    $itemLines = New-Object System.Collections.ArrayList
    foreach ($h in ($awards | Sort-Object { Get-NexLong $_['t'] })) {
        $lk = Get-NexItemLink $items ([string](Get-NexLong $h['id']))
        $label = Get-NexKeyLabel $target ([string]$h['key'])
        $cost = Get-NexLong $h['cost']
        $c = ''; if ($cost -gt 0) { $c = ' · −' + $cost + ' Coins' } elseif ($cost -lt 0) { $c = ' · +' + (-$cost) + ' Coins' }
        [void]$itemLines.Add('**' + $lk + "**`n" + $arrow + ' **' + (ConvertTo-NexDiscordText ([string]$h['name'])) + '** · ' + $label + $c)
    }
    $none = New-Object System.Collections.ArrayList
    foreach ($it in @($e['items'])) {
        if (-not ($it -is [System.Collections.IDictionary])) { continue }
        $w = [string]$it['w']
        $id = [string](Get-NexLong $it['id'])
        if ($w -eq '-') { [void]$none.Add((Get-NexItemLink $items $id)) }
        elseif ($awards.Count -eq 0 -and $w) { # keine Historie (z. B. geloescht): was in der Session steht
            [void]$itemLines.Add('**' + (Get-NexItemLink $items $id) + "**`n" + $arrow + ' **' + (ConvertTo-NexDiscordText $w) + '**')
        }
    }
    $cgLines = New-Object System.Collections.ArrayList
    foreach ($h in ($cg | Sort-Object { Get-NexLong $_['t'] })) {
        $amt = -1 * (Get-NexLong $h['cost'])
        $sign = ''; if ($amt -gt 0) { $sign = '+' }
        $why = [string]$h['why']
        $txt = ConvertTo-NexDiscordText $why
        $ico = Get-NexEmoji 0x1F465
        $m = [regex]::Match($why, '^(\d+) Spieler( \(Ersatzbank\))?(?:: (.*))?$')
        if ($m.Success) {
            $txt = 'für ' + $m.Groups[1].Value + ' Spieler'
            if ($m.Groups[2].Success) { $txt += ' auf der Ersatzbank'; $ico = Get-NexEmoji 0x1FA91 }
            if ($m.Groups[3].Success -and $m.Groups[3].Value) { $txt += ' · ' + (ConvertTo-NexDiscordText $m.Groups[3].Value) }
        }
        [void]$cgLines.Add($ico + ' **' + $sign + $amt + '** ' + $txt)
    }
    # Kopf: Datum, Zeit, Raidleiter, wie viele dabei
    $name = [string]$e['name']; if (-not $name) { $name = 'Raid' }
    $start = Get-NexLong $e['start']; if ($start -le 0) { $start = $sid }
    $stop = Get-NexLong $e['stop']
    $d0 = ([DateTime]'1970-01-01').AddSeconds([double]$start).ToLocalTime()
    $head = (Get-NexEmoji 0x1F4C5) + ' **' + $script:NexDays[[int]$d0.DayOfWeek] + ', ' + $d0.ToString('dd.MM.yyyy', $script:NexInv) + '** · ' + $d0.ToString('HH:mm', $script:NexInv)
    if ($stop -gt 0) { $head += ' – ' + (Format-NexDate $stop 'HH:mm') }
    $head += ' Uhr' + "`n" + (Get-NexEmoji 0x1F451) + ' Raidleiter: **' + (ConvertTo-NexDiscordText ([string]$e['host'])) + '**'
    $mem = $e['members']
    if ($null -ne $mem -and @($mem).Count -gt 0) { $head += ' · ' + (Get-NexEmoji 0x1F465) + ' **' + @($mem).Count + '** dabei' }
    # Raid: Items, Kein Interesse, Raid-Punkte (zur Not werden Items gekuerzt - alles steht in der Webapp)
    $tail = ''
    if ($none.Count -gt 0) { $tail += "`n" + (Get-NexEmoji 0x1F6AB) + ' Kein Interesse: ' + ($none -join ', ') }
    if ($cgLines.Count -gt 0) { $tail += "`n## " + (Get-NexEmoji 0x2B50) + " Raid-Punkte`n" + ($cgLines -join "`n") }
    $itemHead = "`n`n## " + (Get-NexEmoji 0x1F381) + ' Items (' + $itemLines.Count + ")`n"
    $body = ''
    $shown = 0
    foreach ($l in $itemLines) {
        if (($head.Length + $itemHead.Length + $body.Length + $l.Length + $tail.Length + 80) -gt 4000) { break }
        if ($body -ne '') { $body += "`n" }
        $body += $l
        $shown++
    }
    if ($itemLines.Count -eq 0) { $body = 'Keine Items vergeben.' }
    elseif ($shown -lt $itemLines.Count) { $body += "`n… und " + ($itemLines.Count - $shown) + ' weitere (alle in der Webapp)' }
    $raid = [ordered]@{ title = ((Get-NexEmoji 0x2694, 0xFE0F) + ' ' + $name); description = ($head + $itemHead + $body + $tail); color = 16765184 }
    if ($raid['title'].Length -gt 250) { $raid['title'] = $raid['title'].Substring(0, 250) }
    if ($WebUrl -match '^https?://') { $raid['url'] = $WebUrl }
    # Nex-Coins: alle Spieler untereinander, meiste oben, einfach durchnummeriert (gleich viele: nach Namen);
    # dahinter die Aenderung in diesem Raid
    $names = New-Object System.Collections.ArrayList
    foreach ($n in $target['coins'].Keys) { [void]$names.Add([string]$n) }
    $coinLines = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($n in ($names | Sort-Object @{ Expression = { - [long]$target['coins'][$_] } }, @{ Expression = { $_ } })) {
        $i++
        $v = [long]$target['coins'][$n]
        $badge = '`' + $i + '.`'
        $val = [string]$v; if ($v -lt 0) { $val = '−' + (-$v) }
        $dd = Get-NexLong $delta[$n]
        $dt = ''; if ($dd -gt 0) { $dt = ' (+' + $dd + ')' } elseif ($dd -lt 0) { $dt = ' (−' + (-$dd) + ')' }
        [void]$coinLines.Add($badge + ' ' + (ConvertTo-NexDiscordText $n) + ' · **' + $val + '**' + $dt)
    }
    $embeds = New-Object System.Collections.ArrayList
    [void]$embeds.Add($raid)
    $coinHead = '## ' + (Get-NexEmoji 0x1F4B0) + ' Nex-Coins'
    $parts = Split-NexLines $coinLines (4000 - $coinHead.Length - 20)
    for ($j = 0; $j -lt $parts.Count; $j++) {
        $hd = $coinHead; if ($j -gt 0) { $hd += ' (Fortsetzung)' }
        [void]$embeds.Add([ordered]@{ description = ($hd + "`n" + $parts[$j]); color = 16765184 })
    }
    $last = $embeds[$embeds.Count - 1]
    $last['footer'] = [ordered]@{ text = ('NexLoot · Stand ' + $target['rev'] + ' · Coins nach dem Raid') }
    if ($stop -gt 0) { $last['timestamp'] = ([DateTime]'1970-01-01').AddSeconds([double]$stop).ToString('yyyy-MM-ddTHH:mm:ssZ', $script:NexInv) }
    # auf Nachrichten verteilen: je hoechstens 10 Embeds und 5800 Zeichen
    $msgs = New-Object System.Collections.ArrayList
    $cur = New-Object System.Collections.ArrayList; $size = 0
    foreach ($em in $embeds) {
        $sz = Get-NexEmbedSize $em
        if ($cur.Count -gt 0 -and ($cur.Count -ge 10 -or ($size + $sz) -gt 5800)) {
            [void]$msgs.Add($cur); $cur = New-Object System.Collections.ArrayList; $size = 0
        }
        [void]$cur.Add($em); $size += $sz
    }
    if ($cur.Count -gt 0) { [void]$msgs.Add($cur) }
    $out = New-Object System.Collections.ArrayList
    foreach ($list in $msgs) {
        [void]$out.Add([ordered]@{ username = 'NexLoot'; embeds = $list; allowed_mentions = [ordered]@{ parse = (New-Object System.Collections.ArrayList) } })
    }
    return , $out
}
# 1.5: alle Historie-Schluessel einer Session (Items, Raid-Punkte, Coin-Aenderungen) - sortiert
function Get-NexSessKeys($target, [long] $Sid) {
    $keys = New-Object System.Collections.ArrayList
    foreach ($h in $target['history']) { if ((Get-NexLong $h['s']) -eq $Sid) { [void]$keys.Add((Get-NexHistKey $h)) } }
    $sorted = New-Object System.Collections.ArrayList
    foreach ($k in ($keys | Sort-Object)) { [void]$sorted.Add([string]$k) }
    return , $sorted
}
function Get-NexKeyDiff($Before, $Now) {
    $b = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in $Before) { [void]$b.Add([string]$k) }
    $nw = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in $Now) { [void]$nw.Add([string]$k) }
    $res = @{ Added = (New-Object System.Collections.ArrayList); Removed = (New-Object System.Collections.ArrayList) }
    foreach ($k in $Now) { if (-not $b.Contains([string]$k)) { [void]$res.Added.Add([string]$k) } }
    foreach ($k in $Before) { if (-not $nw.Contains([string]$k)) { [void]$res.Removed.Add([string]$k) } }
    return $res
}
# Schluessel "t|name|id|cost|key" -> Eintrag (fuer zurueckgenommene Eintraege, die es nicht mehr gibt)
function ConvertFrom-NexHistKey([string] $K) {
    $p = $K.Split('|')
    if ($p.Count -lt 5) { return $null }
    $h = New-Object System.Collections.Specialized.OrderedDictionary
    $h['t'] = Get-NexLong $p[0]; $h['name'] = $p[1]; $h['id'] = Get-NexLong $p[2]; $h['cost'] = Get-NexLong $p[3]; $h['key'] = $p[4]
    return $h
}
# 1.5: Korrektur zu einer schon geposteten Session: nur was neu dazugekommen bzw. zurueckgenommen wurde
function New-NexDiscordCorrection($target, $e, $Diff, [string] $WebUrl = '') {
    $items = $target['items']
    $byKey = @{}
    foreach ($h in $target['history']) { $byKey[(Get-NexHistKey $h)] = $h }
    $arrow = Get-NexEmoji 0x21B3
    $plus = Get-NexEmoji 0x2795
    $minus = Get-NexEmoji 0x274C
    $loot = New-Object System.Collections.ArrayList
    $pts = New-Object System.Collections.ArrayList
    $who = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    $rows = New-Object System.Collections.ArrayList
    foreach ($k in $Diff.Removed) { $h = ConvertFrom-NexHistKey $k; if ($null -ne $h) { [void]$rows.Add(@{ H = $h; Gone = $true }) } }
    foreach ($k in $Diff.Added) { if ($byKey.ContainsKey($k)) { [void]$rows.Add(@{ H = $byKey[$k]; Gone = $false }) } }
    foreach ($r in ($rows | Sort-Object { Get-NexLong $_.H['t'] })) {
        $h = $r.H
        $kk = [string]$h['key']
        $cost = Get-NexLong $h['cost']
        $nm = ConvertTo-NexDiscordText ([string]$h['name'])
        if ($kk -eq 'CG') {
            $amt = -1 * $cost; $sign = ''; if ($amt -gt 0) { $sign = '+' }
            $txt = '**' + $sign + $amt + '** Raid-Punkte'
            if ($r.Gone) { [void]$pts.Add($minus + ' ~~' + $txt + '~~ zurückgenommen') }
            else {
                $why = [string]$h['why']; if ($why) { $txt += ' · ' + (ConvertTo-NexDiscordText $why) }
                [void]$pts.Add($plus + ' ' + $txt)
            }
            foreach ($n in @($h['p'])) { if ($n) { [void]$who.Add([string]$n) } }
        } elseif ($kk -eq 'C') {
            $amt = -1 * $cost; $sign = ''; if ($amt -gt 0) { $sign = '+' }
            $txt = '**' + $nm + '** ' + $sign + $amt + ' Coins'
            if ($r.Gone) { [void]$pts.Add($minus + ' ~~' + $txt + '~~') } else { [void]$pts.Add($plus + ' ' + $txt) }
            [void]$who.Add([string]$h['name'])
        } elseif (-not $script:NexCoinKeys.ContainsKey($kk) -and (Get-NexLong $h['id']) -gt 0) {
            $lk = Get-NexItemLink $items ([string](Get-NexLong $h['id']))
            $c = ''; if ($cost -gt 0) { $c = ' · −' + $cost + ' Coins' } elseif ($cost -lt 0) { $c = ' · +' + (-$cost) + ' Coins' }
            if ($r.Gone) {
                $back = ''; if ($cost -gt 0) { $back = ' · ' + $cost + ' Coins zurück' }
                [void]$loot.Add($minus + ' ~~**' + $lk + "**~~`n" + $arrow + ' ~~**' + $nm + '**~~ · zurückgenommen' + $back)
            } else {
                [void]$loot.Add($plus + ' **' + $lk + "**`n" + $arrow + ' **' + $nm + '** · ' + (Get-NexKeyLabel $target $kk) + $c)
            }
            if ($cost -ne 0) { [void]$who.Add([string]$h['name']) }
        }
    }
    $name = [string]$e['name']; if (-not $name) { $name = 'Raid' }
    $sid = Get-NexLong $e['sid']
    $start = Get-NexLong $e['start']; if ($start -le 0) { $start = $sid }
    $d0 = ([DateTime]'1970-01-01').AddSeconds([double]$start).ToLocalTime()
    $desc = (Get-NexEmoji 0x1F4C5) + ' **' + $script:NexDays[[int]$d0.DayOfWeek] + ', ' + $d0.ToString('dd.MM.yyyy', $script:NexInv) + '** · nachträglich geändert'
    if ($loot.Count -gt 0) { $desc += "`n`n## " + (Get-NexEmoji 0x1F381) + " Items`n" + ($loot -join "`n") }
    if ($pts.Count -gt 0) { $desc += "`n`n## " + (Get-NexEmoji 0x2B50) + " Raid-Punkte und Coins`n" + ($pts -join "`n") }
    if ($who.Count -gt 0) {
        $cl = New-Object System.Collections.ArrayList
        foreach ($n in $who) {
            $v = 0L; if ($target['coins'].Contains($n)) { $v = [long]$target['coins'][$n] }
            $val = [string]$v; if ($v -lt 0) { $val = '−' + (-$v) }
            [void]$cl.Add((ConvertTo-NexDiscordText $n) + ' · **' + $val + '**')
        }
        $desc += "`n`n## " + (Get-NexEmoji 0x1F4B0) + " Nex-Coins jetzt`n" + ($cl -join "`n")
    }
    if ($desc.Length -gt 4000) { $desc = $desc.Substring(0, 3990) + "`n…" }
    $em = [ordered]@{ title = ((Get-NexEmoji 0x270F, 0xFE0F) + ' Korrektur: ' + $name); description = $desc; color = 16747546 }
    if ($em['title'].Length -gt 250) { $em['title'] = $em['title'].Substring(0, 250) }
    if ($WebUrl -match '^https?://') { $em['url'] = $WebUrl }
    $em['footer'] = [ordered]@{ text = ('NexLoot · Stand ' + $target['rev'] + ' · Korrektur') }
    $stop = Get-NexLong $e['stop']
    if ($stop -gt 0) { $em['timestamp'] = ([DateTime]'1970-01-01').AddSeconds([double]$stop).ToString('yyyy-MM-ddTHH:mm:ssZ', $script:NexInv) }
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add([ordered]@{ username = 'NexLoot'; embeds = @($em); allowed_mentions = [ordered]@{ parse = (New-Object System.Collections.ArrayList) } })
    return , $out
}

# (aeltere Aufrufe: nur die erste Nachricht)
function New-NexDiscordPayload($target, $e, [string] $WebUrl = '') { return (New-NexDiscordMessages $target $e $WebUrl)[0] }

# Mehrere Nachrichten nacheinander. Gilt als gepostet, sobald die erste angekommen ist.
function Send-NexDiscordAll([string] $Url, $Messages) {
    $first = $null
    $sent = 0
    foreach ($m in $Messages) {
        $r = Send-NexDiscord $Url $m
        if (-not $r.Ok -and $r.Retry -gt 0 -and $sent -gt 0 -and $r.Retry -le 10) { Start-Sleep -Seconds $r.Retry; $r = Send-NexDiscord $Url $m }
        if ($null -eq $first) { $first = $r }
        if (-not $r.Ok) {
            if ($sent -eq 0) { return $r }
            $first.Message = 'Discord: Teil ' + ($sent + 1) + ' von ' + @($Messages).Count + ' fehlt (' + $r.Message + ')'
            break
        }
        $sent++
    }
    $first.Sent = $sent
    return $first
}

# An den Webhook schicken. Rueckgabe: @{ Ok; Retry (Sekunden, bei 429); Message } - ohne die Adresse
function Send-NexDiscord([string] $Url, $Payload) {
    $r = @{ Ok = $false; Retry = 0; Message = '' }
    if (-not $Url) { $r.Message = 'kein Webhook eingetragen'; return $r }
    $body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-NexJson $Payload))
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method POST -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 -UseBasicParsing
        $r.Ok = $true
        return $r
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        $msg = Get-NexErrorText $_
        if ($code -eq 429) {
            $r.Retry = 5
            try { $j = ConvertFrom-NexJson $_.ErrorDetails.Message; if ($j['retry_after']) { $r.Retry = [math]::Ceiling([double]$j['retry_after']) } } catch { }
            $r.Message = 'Discord: zu viele Nachrichten, gleich noch einmal'
        } elseif ($code -eq 404 -or $code -eq 401) {
            $r.Message = 'Discord: Webhook gibt es nicht mehr (in Discord gelöscht?) – bitte in den Einstellungen neu eintragen'
        } else {
            $r.Message = 'Discord: ' + $msg
        }
        $r.Message = $r.Message.Replace($Url, '(Webhook)')
        return $r
    }
}

# ---------------------------------------------------------------------------------------------
# 1.6: Woechentlicher Verfall bei Discord - genau einmal, auch wenn mehrere Offiziere die Companion-App haben.
# Merker in der Webapp (bei den Item-Namen unter "_decay"):
#   c / ct / v = wer gerade postet (reserviert), seit wann, fuer welchen Verfall;  dp / by = gepostet (Zeit des Verfalls), von wem.
# Ablauf: 5-15 Minuten nach dem Verfall (je nach Name verschieden) reserviert ein Companion, sieht 20 Sekunden spaeter
# nach, ob die Reservierung noch seine ist, und postet erst dann. Alle anderen sehen Reservierung bzw. Merker und posten nicht.
# ---------------------------------------------------------------------------------------------
function Get-NexLastDecay($target) {
    $v = $null
    foreach ($h in $target['history']) {
        if ([string]$h['key'] -eq 'V' -and ($null -eq $v -or (Get-NexLong $h['t']) -gt (Get-NexLong $v['t']))) { $v = $h }
    }
    return $v
}

# Nachrichten an Discord packen: je hoechstens 10 Embeds und 5800 Zeichen
function ConvertTo-NexDiscordMsgList($Embeds) {
    $msgs = New-Object System.Collections.ArrayList
    $cur = New-Object System.Collections.ArrayList; $size = 0
    foreach ($em in $Embeds) {
        $sz = Get-NexEmbedSize $em
        if ($cur.Count -gt 0 -and ($cur.Count -ge 10 -or ($size + $sz) -gt 5800)) {
            [void]$msgs.Add($cur); $cur = New-Object System.Collections.ArrayList; $size = 0
        }
        [void]$cur.Add($em); $size += $sz
    }
    if ($cur.Count -gt 0) { [void]$msgs.Add($cur) }
    $out = New-Object System.Collections.ArrayList
    foreach ($list in $msgs) {
        [void]$out.Add([ordered]@{ username = 'NexLoot'; embeds = $list; allowed_mentions = [ordered]@{ parse = (New-Object System.Collections.ArrayList) } })
    }
    return , $out
}

# Nachricht zum Verfall: Datum, was passiert ist, darunter alle Spieler mit ihren Nex-Coins (meiste oben)
function New-NexDecayMessages($target, $v, [string] $WebUrl = '') {
    $pct = 10; $wk = 1
    $info = Get-NexDecayInfo ([string]$v['why'])
    if ($null -ne $info) { $pct = $info[0]; $wk = $info[1] }
    $t = Get-NexLong $v['t']
    $d0 = ([DateTime]'1970-01-01').AddSeconds([double]$t).ToLocalTime()
    $desc = (Get-NexEmoji 0x1F4C5) + ' **' + $script:NexDays[[int]$d0.DayOfWeek] + ', ' + $d0.ToString('dd.MM.yyyy', $script:NexInv) + '** · ' + $d0.ToString('HH:mm', $script:NexInv) + ' Uhr'
    if ($wk -gt 1) { $desc += "`n" + 'Nachgeholt für **' + $wk + ' Wochen**: alle Nex-Coins ' + $wk + '× um **' + $pct + ' %** verringert (abgerundet).' }
    else { $desc += "`n" + 'Alle Nex-Coins wurden um **' + $pct + ' %** verringert (abgerundet).' }
    $names = New-Object System.Collections.ArrayList
    foreach ($n in $target['coins'].Keys) { [void]$names.Add([string]$n) }
    $desc += "`n" + (Get-NexEmoji 0x1F465) + ' **' + $names.Count + '** Spieler'
    $coinLines = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($n in ($names | Sort-Object @{ Expression = { - [long]$target['coins'][$_] } }, @{ Expression = { $_ } })) {
        $i++
        $val = [long]$target['coins'][$n]
        $vs = [string]$val; if ($val -lt 0) { $vs = '−' + (-$val) }
        [void]$coinLines.Add('`' + $i + '.` ' + (ConvertTo-NexDiscordText $n) + ' · **' + $vs + '**')
    }
    $title = (Get-NexEmoji 0x1F4C9) + ' Wöchentlicher Verfall −' + $pct + ' %'
    $first = [ordered]@{ title = $title; description = $desc; color = 9206502 }
    if ($WebUrl -match '^https?://') { $first['url'] = $WebUrl }
    $embeds = New-Object System.Collections.ArrayList
    [void]$embeds.Add($first)
    $coinHead = '## ' + (Get-NexEmoji 0x1F4B0) + ' Nex-Coins'
    if ($coinLines.Count -eq 0) { [void]$coinLines.Add('Noch keine Spieler mit Coins.') }
    $parts = Split-NexLines $coinLines (4000 - $coinHead.Length - 20)
    for ($j = 0; $j -lt $parts.Count; $j++) {
        $hd = $coinHead; if ($j -gt 0) { $hd += ' (Fortsetzung)' }
        [void]$embeds.Add([ordered]@{ description = ($hd + "`n" + $parts[$j]); color = 9206502 })
    }
    $last = $embeds[$embeds.Count - 1]
    $last['footer'] = [ordered]@{ text = ('NexLoot · Stand ' + $target['rev'] + ' · Coins nach dem Verfall') }
    $last['timestamp'] = ([DateTime]'1970-01-01').AddSeconds([double]$t).ToString('yyyy-MM-ddTHH:mm:ssZ', $script:NexInv)
    return ConvertTo-NexDiscordMsgList $embeds
}

function Push-NexDecayMark($cfg, $Mark) {
    $it = New-Object System.Collections.Specialized.OrderedDictionary
    $it['_decay'] = $Mark
    return Push-NexExtras $cfg $it $null $null
}

# Teil von Invoke-NexDiscord. $out wird ergaenzt (Posted, Message, Error)
function Invoke-NexDecayPost($ctx, $target, [long] $Now, [int] $Jit, $out) {
    $cfg = $ctx.cfg
    $state = $ctx.state
    $v = Get-NexLastDecay $target
    if ($null -eq $v) { return }
    $vt = Get-NexLong $v['t']
    # nur neue Verfaelle (nach dem Eintragen des Webhooks, hoechstens 2 Tage alt)
    if ($vt -lt (Get-NexLong $cfg.discordSince) -or ($Now - $vt) -gt 2 * 86400 -or $vt -gt $Now + 600) { return }
    $me = ([string]$cfg.name).Trim()
    $mk = $null; if ($target['items'].Contains('_decay')) { $mk = $target['items']['_decay'] }
    if ($null -ne $mk -and (Get-NexLong $mk['dp']) -ge $vt) {
        if ((Get-NexLong $state['decayDone']) -lt $vt) { $state['decayDone'] = $vt; $state['decayBy'] = [string]$mk['by'] }
        return
    }
    if ((Get-NexLong $state['decayDone']) -ge $vt) {
        # schon gepostet (hier gemerkt), aber der Merker fehlt in der Webapp: wieder eintragen, nicht neu posten
        $by = [string]$state['decayBy']; if (-not $by) { $by = $me }
        try { [void](Push-NexDecayMark $cfg ([ordered]@{ dp = $vt; by = $by })) } catch { }
        return
    }
    if ($Now - $vt -lt 300 + $Jit) { return }
    # frisch aus der Webapp: hat inzwischen jemand gepostet oder reserviert?
    $fresh = $null
    try { $fresh = Get-NexWeb $cfg } catch { return }
    if ($null -eq $fresh) { return }
    $fm = $null; if ($fresh['items'].Contains('_decay')) { $fm = $fresh['items']['_decay'] }
    if ($null -ne $fm -and (Get-NexLong $fm['dp']) -ge $vt) { $state['decayDone'] = $vt; $state['decayBy'] = [string]$fm['by']; return }
    $cv = 0L; $cby = ''; $cat = 0L
    if ($null -ne $fm) { $cv = Get-NexLong $fm['v']; $cby = [string]$fm['c']; $cat = Get-NexLong $fm['ct'] }
    if ($cv -eq $vt -and $cby -eq $me) {
        if ($Now - $cat -lt 20) { return } # kurz warten: falls ein anderer gleichzeitig reserviert hat, gewinnt der Letzte
        $src = $fresh; if ($null -eq (Get-NexLastDecay $fresh)) { $src = $target }
        $msgs = New-NexDecayMessages $src $v ([string]$cfg.webUrl)
        $r = Send-NexDiscordAll ([string]$cfg.discordUrl) $msgs
        if (-not $r.Ok) {
            $out.Error = $r.Message
            if ($r.Retry -gt 0) { $state['discordWait'] = $Now + $r.Retry } else { $state['discordWait'] = $Now + 600 }
            return
        }
        $state['decayDone'] = $vt; $state['decayBy'] = $me
        $mark = [ordered]@{ dp = $vt; by = $me }
        try { [void](Push-NexDecayMark $cfg $mark) } catch { $out.Error = 'Discord-Merker nicht in der Webapp: ' + $_.Exception.Message }
        $out.Posted++
        $out.Message = 'Discord: Wöchentlicher Verfall gepostet.'
        return
    }
    if ($cv -eq $vt -and $cby -and [math]::Abs($Now - $cat) -lt 600) { return } # ein anderer Offizier postet gerade
    # reservieren (alter Merker bleibt erhalten)
    $mark = New-Object System.Collections.Specialized.OrderedDictionary
    if ($null -ne $fm -and (Get-NexLong $fm['dp']) -gt 0) { $mark['dp'] = Get-NexLong $fm['dp']; $mark['by'] = [string]$fm['by'] }
    $mark['c'] = $me; $mark['ct'] = $Now; $mark['v'] = $vt
    try { [void](Push-NexDecayMark $cfg $mark) } catch { }
}

# Nach dem Abgleich: fertige Raids posten, die noch niemand gepostet hat. $res = Ergebnis von Invoke-NexSync
function Invoke-NexDiscord($ctx, $res, [long] $Now = 0) {
    $cfg = $ctx.cfg
    $state = $ctx.state
    $out = @{ Posted = 0; Message = ''; Error = '' }
    if (-not $cfg.discordUrl -or $null -eq $res.Target) { return $out }
    if ($Now -le 0) { $Now = Get-NexUnixNow }
    $target = $res.Target
    if (-not $state.Contains('discord')) { $state['discord'] = New-Object System.Collections.Specialized.OrderedDictionary }
    $done = $state['discord']
    if (-not $state.Contains('discordKeys')) { $state['discordKeys'] = New-Object System.Collections.Specialized.OrderedDictionary }
    $doneKeys = $state['discordKeys'] # (1.5) was gepostet wurde, falls der Merker die Webapp nicht erreicht
    foreach ($k in @($doneKeys.Keys)) { if (-not $done.Contains($k)) { $doneKeys.Remove($k) } }
    foreach ($k in @($done.Keys)) { if ($Now - (Get-NexLong $done[$k]) -gt 90 * 86400) { $done.Remove($k) } }
    if ($state.Contains('discordWait') -and (Get-NexLong $state['discordWait']) -gt $Now) { return $out }
    $since = Get-NexLong $cfg.discordSince
    # Jitter pro Name (0-10 Min.), damit zwei Offiziere nicht gleichzeitig posten
    $jit = 0; foreach ($ch in ([string]$cfg.name).ToCharArray()) { $jit = ($jit * 31 + [int]$ch) % 600 }
    $changed = $false
    $webDp = @{} # Stand in der Webapp vor diesem Durchlauf (nur die Zahlen - die Eintraege koennen dieselben sein wie im neuen Stand)
    if ($null -ne $res.Web) { foreach ($w in $res.Web['sessions']) { $webDp[[string]$w['host'] + '|' + [string]$w['sid']] = Get-NexLong $w['dp'] } }
    foreach ($e in $target['sessions']) {
        $key = [string]$e['host'] + '|' + [string]$e['sid']
        $stop = Get-NexLong $e['stop']
        if ($stop -le 0) { continue }
        # schon gepostet (hier gemerkt): Merker auch in die Webapp bringen
        if ($done.Contains($key) -and (Get-NexLong $done[$key]) -ge $stop) {
            if ((Get-NexLong $e['dp']) -lt $stop) { $e['dp'] = $stop }
            if ($null -eq $e['dps'] -and $doneKeys.Contains($key)) { $e['dps'] = $doneKeys[$key] }
            if (-not $webDp.ContainsKey($key) -or $webDp[$key] -lt $stop) { $changed = $true }
            continue
        }
        if ((Get-NexLong $e['dp']) -ge $stop -or $stop -lt $since) { continue }
        # 1.5: schon einmal gepostet, dann wieder geoeffnet: nur die Aenderungen (oder nichts, wenn sich nichts geaendert hat)
        $nowKeys = Get-NexSessKeys $target (Get-NexLong $e['sid'])
        $corr = $null
        if ((Get-NexLong $e['dp']) -gt 0 -and $null -ne $e['dps']) {
            $corr = Get-NexKeyDiff @($e['dps']) $nowKeys
            if ($corr.Added.Count -eq 0 -and $corr.Removed.Count -eq 0) {
                $e['dp'] = $stop; $done[$key] = $stop; $doneKeys[$key] = $nowKeys; $changed = $true
                continue
            }
        }
        $isHost = ($cfg.name -and ([string]$cfg.name).Trim() -eq [string]$e['host'])
        $wait = 0; if (-not $isHost) { $wait = 1800 + $jit }
        if ($Now - $stop -lt $wait) { continue }
        # kurz vorher in der Webapp nachsehen: hat ein anderer Offizier inzwischen gepostet?
        try {
            $fresh = Get-NexWeb $cfg
            $already = $false
            if ($null -ne $fresh) { foreach ($w in $fresh['sessions']) { if (([string]$w['host'] + '|' + [string]$w['sid']) -eq $key -and (Get-NexLong $w['dp']) -ge $stop) { $already = $true } } }
            if ($already) {
                $e['dp'] = $stop
                foreach ($w in $fresh['sessions']) { if (([string]$w['host'] + '|' + [string]$w['sid']) -eq $key -and $null -ne $w['dps']) { $e['dps'] = $w['dps'] } }
                continue
            }
        } catch { }
        if ($null -ne $corr) { $msgs = New-NexDiscordCorrection $target $e $corr ([string]$cfg.webUrl) }
        else { $msgs = New-NexDiscordMessages $target $e ([string]$cfg.webUrl) }
        $r = Send-NexDiscordAll ([string]$cfg.discordUrl) $msgs
        if (-not $r.Ok) {
            $out.Error = $r.Message
            if ($r.Retry -gt 0) { $state['discordWait'] = $Now + $r.Retry } else { $state['discordWait'] = $Now + 600 }
            break
        }
        $done[$key] = $stop
        $doneKeys[$key] = $nowKeys
        $e['dp'] = $stop
        $e['dps'] = $nowKeys
        $changed = $true
        $out.Posted++
        $nm = [string]$e['name']; if (-not $nm) { $nm = 'Raid' }
        if ($null -ne $corr) { $out.Message = 'Discord: Korrektur zu „' + $nm + '“ gepostet.' }
        else { $out.Message = 'Discord: Zusammenfassung „' + $nm + '“ gepostet.' }
    }
    if ($changed) {
        try { [void](Push-NexExtras $cfg $null $null $target['sessions']) } catch { $out.Error = 'Discord-Merker nicht in der Webapp: ' + $_.Exception.Message }
    }
    # 1.6: woechentlicher Verfall (einmal fuer alle)
    if (-not $out.Error) {
        $p0 = $out.Posted; $m0 = $out.Message
        Invoke-NexDecayPost $ctx $target $Now $jit $out
        if ($p0 -gt 0 -and $out.Posted -gt $p0) { $out.Message = $m0 + ' ' + $out.Message }
    }
    return $out
}

# ---------------------------------------------------------------------------------------------
# 1.6: Sicherung per Mail - jeden Abend ein SQL-Dump als Anhang (erst CREATE TABLE, dann der Stand).
# Nur der Companion, bei dem "Sicherung per Mail" eingerichtet ist, schickt sie. Das Mail-Passwort
# (bei Gmail ein App-Passwort) steht nur verschluesselt in config.json und nie im Protokoll.
# ---------------------------------------------------------------------------------------------
$script:NexDumpSchema = @'
create table if not exists public.nexloot_state (
  guild       text primary key,
  rev         bigint      not null default 0,
  data        jsonb       not null default '{}'::jsonb,
  updated_at  timestamptz not null default now(),
  updated_by  text
);
alter table public.nexloot_state enable row level security;
drop policy if exists "nexloot lesen" on public.nexloot_state;
create policy "nexloot lesen" on public.nexloot_state for select to anon, authenticated using (true);
grant select on public.nexloot_state to anon, authenticated;
revoke insert, update, delete on public.nexloot_state from anon, authenticated;
'@

function ConvertTo-NexSqlText($v) {
    if ($null -eq $v -or [string]$v -eq '') { return 'null' }
    return "'" + ([string]$v).Replace("'", "''") + "'"
}

# Alle Zeilen der Tabelle nexloot_state (die darf jeder lesen - die Webapp tut es auch)
function Get-NexStateRows($cfg) {
    $rows = Invoke-NexHttp $cfg 'GET' '/rest/v1/nexloot_state?select=guild,rev,data,updated_at,updated_by&order=guild.asc' $null
    $list = New-Object System.Collections.ArrayList
    foreach ($r in @($rows)) { if ($r -is [System.Collections.IDictionary] -and $r['guild']) { [void]$list.Add($r) } }
    return , $list
}

function New-NexSqlDump($Rows, [DateTime] $When, [string] $By = '', [string] $Version = '') {
    $nl = "`n"
    $sb = New-Object System.Text.StringBuilder
    $app = 'NexLoot Companion-App'; if ($Version) { $app += ' ' + $Version }
    $byTxt = ''; if ($By) { $byTxt = ' (' + $By + ')' }
    [void]$sb.Append('-- =====================================================================' + $nl)
    [void]$sb.Append('-- NexLoot – Sicherung der Datenbank (SQL-Dump)' + $nl)
    [void]$sb.Append('-- Erstellt: ' + $When.ToString('dd.MM.yyyy HH:mm', $script:NexInv) + ' von der ' + $app + $byTxt + $nl)
    foreach ($r in $Rows) {
        $st = ConvertTo-NexState $r['data'] (Get-NexLong $r['rev'])
        $info = '-- Gilde ' + [string]$r['guild'] + ': Stand ' + (Get-NexLong $r['rev'])
        if ($null -ne $st) { $info += ', ' + $st['coins'].Count + ' Spieler, ' + $st['history'].Count + ' Einträge in der Historie, ' + $st['sessions'].Count + ' Sessions' }
        [void]$sb.Append($info + $nl)
    }
    [void]$sb.Append('--' + $nl)
    [void]$sb.Append('-- Zurückspielen: Supabase → SQL Editor → den ganzen Inhalt dieser Datei einfügen → Run.' + $nl)
    [void]$sb.Append('--   1. Legt die Tabelle nexloot_state an, falls sie fehlt (create table if not exists).' + $nl)
    [void]$sb.Append('--   2. Schreibt den gesicherten Stand hinein (ersetzt den Stand der Gilde).' + $nl)
    [void]$sb.Append('-- Bei einer ganz neuen Datenbank vorher nexloot.sql und nexloot_verfall.sql ausführen' + $nl)
    [void]$sb.Append('-- (Funktionen, Schreib-Passwort, Verfall). Danach gleichen die Companion-Apps wieder ab.' + $nl)
    [void]$sb.Append('-- =====================================================================' + $nl + $nl)
    [void]$sb.Append('begin;' + $nl + $nl)
    [void]$sb.Append($script:NexDumpSchema.Replace("`r`n", "`n").TrimEnd() + $nl + $nl)
    foreach ($r in $Rows) {
        $json = ConvertTo-NexJson $r['data']
        $tag = '$nexloot$'; $n = 0
        while ($json.Contains($tag)) { $n++; $tag = '$nexloot' + $n + '$' }
        [void]$sb.Append('insert into public.nexloot_state (guild, rev, data, updated_at, updated_by)' + $nl)
        [void]$sb.Append('values (' + (ConvertTo-NexSqlText $r['guild']) + ', ' + (Get-NexLong $r['rev']) + ', ' + $tag + $json + $tag + '::jsonb, ')
        $ua = ConvertTo-NexSqlText $r['updated_at']; if ($ua -eq 'null') { $ua = 'now()' } else { $ua += '::timestamptz' }
        [void]$sb.Append($ua + ', ' + (ConvertTo-NexSqlText $r['updated_by']) + ')' + $nl)
        [void]$sb.Append('on conflict (guild) do update set rev = excluded.rev, data = excluded.data, updated_at = excluded.updated_at, updated_by = excluded.updated_by;' + $nl + $nl)
    }
    [void]$sb.Append('commit;' + $nl)
    return $sb.ToString()
}

# Mail mit Anhang schicken. $Mail: @{ to; from; user; pass; host; port; ssl }
function Send-NexMail($Mail, [string] $Subject, [string] $Body, [string] $AttachName, [string] $AttachText) {
    $msg = New-Object System.Net.Mail.MailMessage
    $cl = $null
    try {
        $msg.From = New-Object System.Net.Mail.MailAddress(([string]$Mail.from), 'NexLoot Companion')
        foreach ($to in ([string]$Mail.to -split '[,; ]+')) { if ($to) { $msg.To.Add($to) } }
        $msg.Subject = $Subject
        $msg.SubjectEncoding = [System.Text.Encoding]::UTF8
        $msg.Body = $Body
        $msg.BodyEncoding = [System.Text.Encoding]::UTF8
        if ($AttachName) {
            $bytes = $script:NexUtf8.GetBytes($AttachText)
            $ms = New-Object System.IO.MemoryStream(, $bytes)
            $att = New-Object System.Net.Mail.Attachment($ms, $AttachName, 'text/plain')
            $att.ContentType.CharSet = 'utf-8'
            $msg.Attachments.Add($att)
        }
        $cl = New-Object System.Net.Mail.SmtpClient(([string]$Mail.host), ([int]$Mail.port))
        $cl.EnableSsl = [bool]$Mail.ssl
        $cl.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
        $cl.UseDefaultCredentials = $false
        if ($Mail.user) { $cl.Credentials = New-Object System.Net.NetworkCredential(([string]$Mail.user), ([string]$Mail.pass)) }
        $cl.Timeout = 30000
        $cl.Send($msg)
    } finally {
        $msg.Dispose()
        if ($null -ne $cl) { $cl.Dispose() }
    }
}

# Fehlertext fuer Menschen (ohne Passwort)
function Get-NexMailError($err, $Mail) {
    $parts = New-Object System.Collections.ArrayList
    $e = $err.Exception
    while ($null -ne $e) { if ($e.Message -and -not $parts.Contains($e.Message)) { [void]$parts.Add($e.Message) }; $e = $e.InnerException }
    $m = ($parts -join ' – ')
    if ($Mail -and $Mail.pass) { $m = $m.Replace([string]$Mail.pass, '***') }
    if ($m -match '5\.7\.[0-9]|535|Authentication|authenticated|not accepted|Anmeldung') {
        return 'Anmeldung beim Mailserver abgelehnt – bitte Absender und App-Passwort prüfen (bei Gmail geht nur ein App-Passwort, nicht das normale Passwort).'
    }
    if ($m -match 'remote name|Remotename|Remoteserver|No such host|resolve|actively refused|verweigert|timed out|Zeitüberschreitung|Unable to connect|Failure sending|Fehler beim Senden') {
        return 'Mailserver nicht erreichbar (' + $m + ')'
    }
    return $m
}

# Welcher Abend ist dran? Vor der eingestellten Uhrzeit: der gestrige, danach: der heutige
function Get-NexBackupSlot([DateTime] $Now, [int] $Hour) {
    $d = $Now.Date
    if ($Now.Hour -lt $Hour) { $d = $d.AddDays(-1) }
    return $d.ToString('yyyy-MM-dd', $script:NexInv)
}

# Einmal pro Abend (bzw. nachgeholt, wenn der PC am Abend aus war). -Force: jetzt sofort (Test im Dialog / Menue)
function Invoke-NexBackup($ctx, $Mail, [DateTime] $Now = [DateTime]::MinValue, [switch] $Force) {
    $out = @{ Sent = $false; Message = ''; Error = '' }
    if ($null -eq $Mail -or -not $Mail.to -or -not $Mail.host -or -not $Mail.from) { return $out }
    if (-not $Force -and -not $Mail.on) { return $out }
    if ($Now -eq [DateTime]::MinValue) { $Now = [DateTime]::Now }
    $state = $ctx.state
    $unix = [long][math]::Floor(($Now.ToUniversalTime() - [DateTime]'1970-01-01').TotalSeconds)
    $slot = Get-NexBackupSlot $Now ([int]$Mail.hour)
    if (-not $Force) {
        if ([string]::CompareOrdinal([string]$state['backupSlot'], $slot) -ge 0) { return $out }
        $fail = Get-NexLong $state['backupFailAt']
        if ($fail -gt 0 -and $unix - $fail -lt 1800 -and $unix -ge $fail) { return $out } # nach einem Fehler 30 Minuten warten
    }
    try {
        $rows = Get-NexStateRows $ctx.cfg
        if ($rows.Count -eq 0) { throw 'In der Datenbank ist noch kein Stand – nichts zu sichern.' }
        $ver = ''; if ($script:AppVersion) { $ver = [string]$script:AppVersion }
        $sql = New-NexSqlDump $rows $Now ([string]$ctx.cfg.name) $ver
        $main = $rows[0]
        foreach ($r in $rows) { if ([string]$r['guild'] -eq [string]$ctx.cfg.guild) { $main = $r } }
        $file = 'NexLoot-Sicherung-' + $Now.ToString('yyyy-MM-dd', $script:NexInv) + '.sql'
        $kb = [math]::Ceiling($script:NexUtf8.GetByteCount($sql) / 1024)
        $subject = 'NexLoot Sicherung ' + $Now.ToString('dd.MM.yyyy', $script:NexInv) + ' – Gilde ' + [string]$main['guild'] + ', Stand ' + (Get-NexLong $main['rev'])
        $body = "Hallo,`r`n`r`nim Anhang die tägliche Sicherung der NexLoot-Datenbank (" + $file + ', ' + $kb + " KB).`r`n" +
            'Gilde ' + [string]$main['guild'] + ', Stand ' + (Get-NexLong $main['rev']) + ', zuletzt geändert von ' + [string]$main['updated_by'] + ".`r`n`r`n" +
            "Zurückspielen: in Supabase im SQL Editor den Inhalt der Datei einfügen und ausführen (Run).`r`n" +
            "Die Datei legt zuerst die Tabelle an (falls sie fehlt) und schreibt dann den Stand hinein.`r`n`r`n" +
            '– NexLoot Companion ' + $ver + ' (' + [string]$ctx.cfg.name + ')'
        Send-NexMail $Mail $subject $body $file $sql
        if ([string]::CompareOrdinal([string]$state['backupSlot'], $slot) -lt 0) { $state['backupSlot'] = $slot }
        $state['backupAt'] = $unix
        if ($state.Contains('backupFailAt')) { $state.Remove('backupFailAt') }
        $out.Sent = $true
        $out.Message = 'Sicherung per Mail an ' + [string]$Mail.to + ' geschickt (Stand ' + (Get-NexLong $main['rev']) + ', ' + $kb + ' KB).'
    } catch {
        $state['backupFailAt'] = $unix
        $out.Error = 'Sicherung per Mail: ' + (Get-NexMailError $_ $Mail)
    }
    return $out
}
