<#
    Rebuilds everything from zero (acceptance criterion AC-01):
      1. generates the synthetic ERP exports and the budget workbook (generator\generate_data.py)
      2. creates or updates the database objects (database\deploy.ps1)
      3. loads the exports into the src schema (database\load_source_data.py)
      4. runs a full load into dw and the data quality checks (database\refresh.ps1 -FullReload)
      5. writes the semantic model, pointing its Budget File parameter at this clone (powerbi\generate_model.py)
    Then open powerbi\VelmoraSales.pbip in Power BI Desktop and refresh.

    Usage:  powershell -ExecutionPolicy Bypass -File build.ps1 [-Server localhost] [-Seed 7]
    Needs: SQL Server reachable with Windows authentication, Python 3.11+ with requirements.txt installed
           (a .venv in this folder is used when present), ODBC Driver 18 for SQL Server.
#>
param(
    [string]$Server = "localhost",
    [int]$Seed = 7
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$python = Join-Path $root ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) { $python = "python" }

& $python -X utf8 "$root\generator\generate_data.py" --seed $Seed --out "$root\data\generated"
if ($LASTEXITCODE -ne 0) { throw "Data generator failed (exit code $LASTEXITCODE)" }

& "$root\database\deploy.ps1" -Server $Server

& $python -X utf8 "$root\database\load_source_data.py" --server $Server
if ($LASTEXITCODE -ne 0) { throw "Source load failed (exit code $LASTEXITCODE)" }

& "$root\database\refresh.ps1" -Server $Server -FullReload

& $python -X utf8 "$root\powerbi\generate_model.py"
if ($LASTEXITCODE -ne 0) { throw "Semantic model generation failed (exit code $LASTEXITCODE)" }
