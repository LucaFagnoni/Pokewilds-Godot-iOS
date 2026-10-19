# Runs PokeWilds.exe --headless --server outside this console and shows its log.
# A release build of Godot dies at once on Ctrl+C or when its console closes, so
# the server never owns the console: Ctrl+C here sends it "stop", and closing
# this window closes its input pipe, which the server also takes as "stop".
# Either way it saves the world before it exits. Typed lines are sent as commands.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = Join-Path $PSScriptRoot 'PokeWilds.exe'
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
