<#
    Processing cycle meant to run on a schedule before the Power BI refresh:
      1. etl.usp_LoadSales  loads what changed in src since the last run (everything with -FullReload)
      2. dq.usp_RunChecks   runs the data quality checks
    Exits with an error when the load or any check fails, so an orchestrator can hold the Power BI refresh.
    No schedule is configured in this project; this is the command a scheduler would call.

    Usage:  powershell -ExecutionPolicy Bypass -File database\refresh.ps1 [-Server localhost] [-FullReload]
#>
param(
    [string]$Server = "localhost",
    [switch]$FullReload
)

$ErrorActionPreference = "Stop"

function Invoke-Query($connection, [string]$sql, [int]$timeout) {
    $command = $connection.CreateCommand()
    $command.CommandText = $sql
    $command.CommandTimeout = $timeout
    $table = New-Object System.Data.DataTable
    $table.Load($command.ExecuteReader())
    return , $table
}

$connection = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=VelmoraSales;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
$connection.Open()
try {
    Write-Host "Running etl.usp_LoadSales"
    $run = Invoke-Query $connection "EXEC etl.usp_LoadSales @FullReload = $([int][bool]$FullReload);" 900
    $run | Format-List | Out-String | Write-Host

    Write-Host "Running dq.usp_RunChecks"
    $checks = Invoke-Query $connection "EXEC dq.usp_RunChecks;" 300
    $checks | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    $failed = @($checks | Where-Object { $_.Result -ne 'Pass' })
    if ($failed.Count -gt 0) { throw "$($failed.Count) data quality check(s) failed" }
}
finally {
    $connection.Close()
}
