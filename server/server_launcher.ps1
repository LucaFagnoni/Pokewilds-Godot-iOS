# Runs PokeWilds.exe --headless --server outside this console and shows its log.
# A release build of Godot dies at once on Ctrl+C or when its console closes, so
# the server never owns the console: Ctrl+C here sends it "stop", and closing
# this window closes its input pipe, which the server also takes as "stop".
# Either way it saves the world before it exits. Typed lines are sent as commands.
$exe = Join-Path $PSScriptRoot 'PokeWilds.exe'

# Windows asks once whether the server may be reached, and by default only on
# "private" networks, while many home networks are set to "public"; a refusal
# becomes a block rule. One allow rule for this program on every network type
# (and no block rule) avoids all of that. Adding it needs administrator rights,
# so Windows asks for permission the first time only.
$rules = @(Get-NetFirewallApplicationFilter -Program $exe -ErrorAction SilentlyContinue | Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' })
$allowed = $rules | Where-Object { $_.Action -eq 'Allow' -and $_.Profile -eq 'Any' }
$blocked = $rules | Where-Object { $_.Action -eq 'Block' }
if (-not $allowed -or $blocked) {
    Write-Host 'Letting PokeWilds through the Windows firewall (Windows asks for permission once)...'
    $quoted = $exe.Replace("'", "''")
    $fix = "Get-NetFirewallApplicationFilter -Program '$quoted' | Get-NetFirewallRule | Where-Object { `$_.Direction -eq 'Inbound' -and `$_.Action -eq 'Block' } | Remove-NetFirewallRule; " +
        "New-NetFirewallRule -DisplayName 'PokeWilds server' -Direction Inbound -Program '$quoted' -Action Allow -Profile Any | Out-Null"
    try { Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', $fix }
    catch { Write-Host 'Firewall not changed: players may not reach the server (see README_SERVER.md).' }
}

# A sleeping PC drops every player: stay awake while the server runs (the
# screen may still turn off). Windows lifts this when this window closes.
Add-Type -Namespace PokeWilds -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);'
[void][PokeWilds.Power]::SetThreadExecutionState([uint32]2147483649)  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = (@('--headless', '--server') + $args) -join ' '
$psi.WorkingDirectory = $PSScriptRoot
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$server = [System.Diagnostics.Process]::Start($psi)
$console = -not [Console]::IsInputRedirected
if ($console) { [Console]::TreatControlCAsInput = $true }
$out = $server.StandardOutput.ReadLineAsync()
$err = $server.StandardError.ReadLineAsync()
$typed = ''
while ($out -ne $null -or $err -ne $null) {
    if ($out -ne $null -and $out.IsCompleted) {
        if ($out.Result -eq $null) { $out = $null } else { [Console]::WriteLine($out.Result); $out = $server.StandardOutput.ReadLineAsync() }
        continue
    }
    if ($err -ne $null -and $err.IsCompleted) {
        if ($err.Result -eq $null) { $err = $null } else { [Console]::WriteLine($err.Result); $err = $server.StandardError.ReadLineAsync() }
        continue
    }
    while ($console -and -not $server.HasExited -and [Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'C' -and $key.Modifiers -band [ConsoleModifiers]::Control) { $typed = 'stop' }
        elseif ($key.Key -eq 'Backspace') { if ($typed.Length -gt 0) { $typed = $typed.Substring(0, $typed.Length - 1); [Console]::Write("`b `b") }; continue }
        elseif ($key.Key -ne 'Enter') { $typed += $key.KeyChar; [Console]::Write($key.KeyChar); continue }
        [Console]::WriteLine()
        $server.StandardInput.WriteLine($typed)
        $typed = ''
    }
    Start-Sleep -Milliseconds 50
}
$server.WaitForExit()
exit $server.ExitCode
