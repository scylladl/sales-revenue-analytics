<#
    Runs every numbered .sql script in this folder, in order, against a SQL Server instance.
    Uses Windows authentication and the .NET client built into Windows PowerShell,
    so it needs neither sqlcmd nor stored passwords.

    Usage:  powershell -ExecutionPolicy Bypass -File database\deploy.ps1 [-Server localhost]
#>
param(
    [string]$Server = "localhost"
)

$ErrorActionPreference = "Stop"
$scripts = Get-ChildItem -Path $PSScriptRoot -Filter "*.sql" | Where-Object { $_.Name -match '^\d{2}_' } | Sort-Object Name
if (-not $scripts) { throw "No numbered .sql scripts found in $PSScriptRoot" }

$connection = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
$connection.Open()
try {
    foreach ($script in $scripts) {
        Write-Host "Running $($script.Name)"
        $text = Get-Content -Path $script.FullName -Raw -Encoding UTF8
        # A GO line ends a batch, as in SSMS and sqlcmd
        $batches = [regex]::Split($text, '^\s*GO\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        foreach ($batch in $batches) {
            if ([string]::IsNullOrWhiteSpace($batch)) { continue }
            $command = $connection.CreateCommand()
            $command.CommandText = $batch
            $command.CommandTimeout = 300
            [void]$command.ExecuteNonQuery()
        }
    }
    Write-Host "Done: $($scripts.Count) script(s) on $Server"
}
finally {
    $connection.Close()
}
