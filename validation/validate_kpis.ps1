<#
    Compares the Power BI measures with an independent SQL calculation on the source tables (acceptance criterion AC-03).

      SQL side:  validation\kpi_source.sql on VelmoraSales (src tables only)
      DAX side:  the same KPIs evaluated in the semantic model of powerbi\VelmoraSales.pbip, which must be open in
                 Power BI Desktop with its data refreshed
    Both sides are computed by year, for all channels and for each channel. Amounts must match to the cent and
    ratios to 0.0001. Also checks that the prepared budget equals the Total rows of the finance workbook.
    Writes validation\kpi_comparison.csv and exits with an error when a KPI differs.

    Usage:  powershell -ExecutionPolicy Bypass -File validation\validate_kpis.ps1 [-Server localhost]
#>
param(
    [string]$Server = "localhost"
)

$ErrorActionPreference = "Stop"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$kpis = "Gross Sales", "Discounts", "Returns", "Net Revenue", "COGS", "Gross Profit", "Gross Margin %", "Discount Rate %",
        "Return Rate %", "Units Sold", "Invoiced Orders", "Average Order Value", "Orders", "Cancelled Orders"
$ratios = "Gross Margin %", "Discount Rate %", "Return Rate %"

# SQL side
$sql = @{}
$connection = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=VelmoraSales;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
$connection.Open()
try {
    $command = $connection.CreateCommand()
    $command.CommandText = Get-Content (Join-Path $PSScriptRoot "kpi_source.sql") -Raw -Encoding UTF8
    $command.CommandTimeout = 600
    $reader = $command.ExecuteReader()
    while ($reader.Read()) {
        $value = if ($reader.IsDBNull(3)) { $null } else { [double]$reader.GetValue(3) }
        $sql["$($reader.GetValue(0))|$($reader.GetValue(1))|$($reader.GetValue(2))"] = $value
    }
}
finally {
    $connection.Close()
}

# DAX side: the Analysis Services instance of the Power BI Desktop window that has VelmoraSales open
$desktop = Get-AppxPackage -Name Microsoft.MicrosoftPowerBIDesktop | Select-Object -First 1
$bin = if ($desktop) { Join-Path $desktop.InstallLocation "bin" } else { "C:\Program Files\Microsoft Power BI Desktop\bin" }
Add-Type -Path (Join-Path $bin "Microsoft.PowerBI.AdomdClient.dll")
$workspaces = "$env:USERPROFILE\Microsoft\Power BI Desktop Store App\AnalysisServicesWorkspaces", "$env:LOCALAPPDATA\Microsoft\Power BI Desktop\AnalysisServicesWorkspaces"
$portFiles = Get-ChildItem -Path $workspaces -Filter msmdsrv.port.txt -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
$dax = $null
foreach ($file in $portFiles) {
    $port = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::Unicode).Trim()
    $candidate = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection "Data Source=localhost:$port"
    try { $candidate.Open() } catch { continue }
    $probe = $candidate.CreateCommand()
    $probe.CommandText = "EVALUATE ROW(""Budget rows"", COUNTROWS('Budget'))"
    try { $probe.ExecuteReader().Close(); $dax = $candidate; break } catch { $candidate.Close() }
}
if (-not $dax) { throw "Open powerbi\VelmoraSales.pbip in Power BI Desktop and refresh it first." }

function Invoke-Dax([string]$query) {
    $command = $dax.CreateCommand()
    $command.CommandText = $query
    $reader = $command.ExecuteReader()
    $names = 0..($reader.FieldCount - 1) | ForEach-Object { $reader.GetName($_) -replace '^.*\[(.*)\]$', '$1' }
    $rows = while ($reader.Read()) {
        $row = @{}
        for ($i = 0; $i -lt $reader.FieldCount; $i++) { $row[$names[$i]] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) } }
        $row
    }
    $reader.Close()
    return $rows
}

$columns = ($kpis | ForEach-Object { """$_"", [$_]" }) -join ", "
$daxValues = @{}
foreach ($row in Invoke-Dax "EVALUATE SUMMARIZECOLUMNS('Date'[Year], $columns)") {
    foreach ($kpi in $kpis) { $daxValues["$($row['Year'])|ALL|$kpi"] = $row[$kpi] }
}
foreach ($row in Invoke-Dax "EVALUATE SUMMARIZECOLUMNS('Date'[Year], 'Channel'[Channel Code], $columns)") {
    foreach ($kpi in $kpis) { $daxValues["$($row['Year'])|$($row['Channel Code'])|$kpi"] = $row[$kpi] }
}

$results = foreach ($key in ($sql.Keys | Sort-Object)) {
    $year, $channel, $kpi = $key -split '\|'
    $expected = $sql[$key]
    $actual = if ($null -ne $daxValues[$key]) { [double]$daxValues[$key] } else { $null }
    $tolerance = if ($ratios -contains $kpi) { 0.0001 } else { 0.005 }
    $match = if ($null -eq $expected -or $null -eq $actual) { $null -eq $expected -and $null -eq $actual }
             else { [math]::Abs($expected - $actual) -le $tolerance }
    [pscustomobject]@{ Year = $year; Channel = $channel; Kpi = $kpi; Sql = $expected; PowerBI = $actual; Match = $match }
}

# Budget: the prepared table against the workbook's own Total rows, by year
$budget = Invoke-Dax @"
EVALUATE
ADDCOLUMNS (
    VALUES ( 'Date'[Year] ),
    "Workbook", CALCULATE ( SUM ( 'Budget Workbook Total'[Amount] ), 'Budget Workbook Total'[Measure] = "Net revenue",
                            YEAR ( 'Budget Workbook Total'[Month Start] ) = EARLIER ( 'Date'[Year] ) ),
    "Prepared", [Budget Net Revenue]
)
"@
$results += foreach ($row in $budget) {
    [pscustomobject]@{ Year = $row["Year"]; Channel = "ALL"; Kpi = "Budget Net Revenue vs workbook Total row";
                       Sql = [double]$row["Workbook"]; PowerBI = [double]$row["Prepared"];
                       Match = [math]::Abs([double]$row["Workbook"] - [double]$row["Prepared"]) -le 0.005 }
}
$dax.Close()

$csv = Join-Path $PSScriptRoot "kpi_comparison.csv"
$results | Select-Object Year, Channel, Kpi,
    @{ n = "Sql"; e = { if ($null -ne $_.Sql) { $_.Sql.ToString("0.######", $invariant) } } },
    @{ n = "PowerBI"; e = { if ($null -ne $_.PowerBI) { $_.PowerBI.ToString("0.######", $invariant) } } }, Match |
    Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

$failed = @($results | Where-Object { -not $_.Match })
Write-Host ("{0} comparisons, {1} differences. Details: {2}" -f $results.Count, $failed.Count, $csv)
if ($failed) {
    $failed | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    throw "$($failed.Count) KPI value(s) differ between SQL and Power BI"
}
