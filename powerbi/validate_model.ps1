<#
    Offline check of the TMDL semantic model with the Tabular Object Model (TOM) that ships
    with Power BI Desktop: parses every .tmdl file, resolves references (tables, columns,
    relationships, sort-by columns) and prints a summary of the model.

    It does not evaluate DAX; measures are checked against SQL in validation\ once the
    model is open in Power BI Desktop.

    Usage:  powershell -ExecutionPolicy Bypass -File powerbi\validate_model.ps1
#>
$ErrorActionPreference = "Stop"

$desktop = Get-AppxPackage -Name Microsoft.MicrosoftPowerBIDesktop | Select-Object -First 1
$bin = if ($desktop) { Join-Path $desktop.InstallLocation "bin" } else { "C:\Program Files\Microsoft Power BI Desktop\bin" }
Add-Type -Path (Join-Path $bin "Microsoft.PowerBI.Tabular.dll")

$folder = Join-Path $PSScriptRoot "VelmoraSales.SemanticModel\definition"
try {
    $database = [Microsoft.AnalysisServices.Tabular.TmdlSerializer]::DeserializeDatabaseFromFolder($folder)
}
catch {
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    $where = if ($e.PSObject.Properties["Document"]) { " ($($e.Document), line $($e.Line))" } else { "" }
    Write-Host "TMDL is not valid$($where): $($e.Message)" -ForegroundColor Red
    exit 1
}

# DAX keywords that parse in TMDL but break a measure when used as a variable name
$reserved = "BEFORE|AFTER|TOP|CELLS|START|END|ORDER|PARTITION|MATCHBY|WINDOW|INDEX|OFFSET|RANK|ROWNUMBER|ASC|DESC|DEFINE|EVALUATE|MEASURE|VAR|RETURN|TRUE|FALSE|NOT|IN"
$badVars = Get-ChildItem -Path $folder -Recurse -Filter *.tmdl |
    Select-String -Pattern "\bVAR\s+($reserved)\s*=" -CaseSensitive:$false
if ($badVars) {
    $badVars | ForEach-Object { Write-Host "Reserved word used as a DAX variable: $($_.Filename):$($_.LineNumber) $($_.Line.Trim())" -ForegroundColor Red }
    exit 1
}

$model = $database.Model
Write-Host ("Model OK: {0} tables, {1} measures, {2} relationships, compatibility level {3}" -f `
    $model.Tables.Count, ($model.Tables | ForEach-Object { $_.Measures.Count } | Measure-Object -Sum).Sum,
    $model.Relationships.Count, $database.CompatibilityLevel)
foreach ($table in $model.Tables) {
    Write-Host ("  {0,-20} columns {1,3}  measures {2,3}" -f $table.Name, $table.Columns.Count, $table.Measures.Count)
}
