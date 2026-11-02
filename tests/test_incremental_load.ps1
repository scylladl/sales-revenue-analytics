<#
    Proves that the incremental load leaves dw exactly as a full reload would (acceptance criterion AC-05).

      1. reload the source exports and run a full load (known starting point)
      2. apply one day of ERP activity (tests\simulate_erp_changes.sql) and run the incremental load
      3. run a full reload: it must find nothing to insert, update or delete, and the fact checksums must not move
      4. run the incremental load again: it must find nothing to do
      5. reload the source exports and run a full load, so the database matches the repository again

    Runs against the VelmoraSales database on -Server. Exits with an error when an assertion fails.

    Usage:  powershell -ExecutionPolicy Bypass -File tests\test_incremental_load.ps1 [-Server localhost]
#>
param(
    [string]$Server = "localhost"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$python = Join-Path $repo ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) { $python = "python" }
$failures = 0

function Invoke-Query([string]$sql) {
    $command = $connection.CreateCommand()
    $command.CommandText = $sql
    $command.CommandTimeout = 900
    $table = New-Object System.Data.DataTable
    $table.Load($command.ExecuteReader())
    return , $table
}

function Assert([string]$name, [bool]$condition, [string]$detail) {
    if ($condition) { Write-Host "PASS  $name  $detail" }
    else { Write-Host "FAIL  $name  $detail"; $script:failures++ }
}

function Reset-Database {
    & $python (Join-Path $repo "database\load_source_data.py") --server $Server | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "load_source_data.py failed" }
    [void](Invoke-Query "EXEC etl.usp_LoadSales @FullReload = 1;")
}

$checksumSql = @"
SELECT (SELECT COUNT(*) FROM dw.FactSales) AS SalesRows,
       (SELECT SUM(NetRevenue) FROM dw.FactSales) AS NetRevenue,
       (SELECT SUM(Cogs) FROM dw.FactSales) AS Cogs,
       (SELECT CHECKSUM_AGG(CHECKSUM(DocumentId, DocumentLine, LineType, OrderId, OrderLineNumber, InvoiceId, PostingDate,
                                     OriginalInvoiceDate, OrderDate, CustomerKey, ProductKey, ChannelCode, RegionCode,
                                     CategoryCode, CampaignCode, ReturnReason, Quantity, UnitListPrice, DiscountPct,
                                     GrossSales, DiscountAmount, ReturnAmount, NetRevenue, UnitCost, Cogs,
                                     IsCostCarriedForward, IsQuantityCapped, IsInvoiceBeforeOrder, IsPolicyChecked,
                                     DiscountAbovePolicy, PromotionPeriod))
        FROM dw.FactSales) AS SalesChecksum,
       (SELECT COUNT(*) FROM dw.FactOrderLine) AS OrderLineRows,
       (SELECT CHECKSUM_AGG(CHECKSUM(OrderId, LineNumber, OrderDate, OrderStatus, CancelledDate, InvoiceDate, CustomerKey,
                                     ProductKey, ChannelCode, RegionCode, CategoryCode, CampaignCode, Quantity, OrderValue))
        FROM dw.FactOrderLine) AS OrderLineChecksum;
"@

$connection = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=VelmoraSales;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
$connection.Open()
try {
    Write-Host "1. Reloading the source exports and running a full load"
    Reset-Database
    $before = (Invoke-Query $checksumSql).Rows[0]

    Write-Host "2. Simulating ERP changes and running the incremental load"
    [void](Invoke-Query (Get-Content (Join-Path $PSScriptRoot "simulate_erp_changes.sql") -Raw -Encoding UTF8))
    $incremental = (Invoke-Query "EXEC etl.usp_LoadSales;").Rows[0]
    $incremental | Format-List AffectedOrders, SalesInserted, SalesUpdated, SalesDeleted, OrderLinesInserted, OrderLinesUpdated, OrderLinesDeleted | Out-String | Write-Host
    $afterIncremental = (Invoke-Query $checksumSql).Rows[0]

    Assert "incremental picked up the changes" ($incremental.SalesInserted -gt 0 -and $incremental.SalesUpdated -gt 0 -and $incremental.OrderLinesUpdated -gt 0) `
        "affected orders $($incremental.AffectedOrders)"

    $expect = Invoke-Query @"
SELECT (SELECT COUNT(*) FROM dw.FactSales WHERE InvoiceId LIKE 'FVT%' AND PostingDate = '2026-01-02') AS NewInvoiceRows,
       (SELECT COUNT(*) FROM src.SalesOrderLine AS l JOIN src.Invoice AS i ON i.OrderId = l.OrderId
         WHERE i.InvoiceId LIKE 'FVT%') AS NewInvoiceLines,
       (SELECT COUNT(*) FROM dw.FactSales AS f JOIN src.SalesOrder AS o ON o.OrderId = f.OrderId
         WHERE o.Status = 'Cancelled') AS CancelledRevenueRows,
       (SELECT COUNT(*) FROM dw.FactSales WHERE DocumentId = 'ABT000001' AND Quantity = -1 AND Cogs < 0) AS RestockedReturn,
       (SELECT COUNT(*) FROM dw.FactSales WHERE DocumentId = 'ABT000002' AND Quantity = 0 AND IsQuantityCapped = 1) AS CappedReturn,
       (SELECT COUNT(*) FROM dw.FactSales AS f JOIN dw.DimProduct AS p ON p.ProductKey = f.ProductKey
         WHERE p.ProductId = 'VEL-BN-03K' AND YEAR(f.OriginalInvoiceDate) = 2024 AND MONTH(f.OriginalInvoiceDate) = 9
           AND f.IsCostCarriedForward = 1) AS StillCarriedForward,
       (SELECT COUNT(*) FROM dw.FactSales AS f JOIN dw.DimCustomer AS c ON c.CustomerKey = f.CustomerKey
         JOIN src.Customer AS s ON s.CustomerId = c.CustomerId
         WHERE s.ModifiedAt = '2026-01-02T08:00:00' AND f.RegionCode <> 'MAD') AS MovedCustomerRowsNotMoved,
       (SELECT COUNT(*) FROM dw.DimProduct WHERE ProductName LIKE N'% (new pack)') AS RenamedProducts;
"@
    $e = $expect.Rows[0]
    Assert "new invoices are revenue on their invoice date" ($e.NewInvoiceRows -gt 0 -and $e.NewInvoiceRows -eq $e.NewInvoiceLines) "$($e.NewInvoiceRows) rows"
    Assert "cancelled orders carry no revenue" ($e.CancelledRevenueRows -eq 0) ""
    Assert "equipment return reverses its cost" ($e.RestockedReturn -eq 1) ""
    Assert "return above the invoiced quantity is capped" ($e.CappedReturn -eq 1) ""
    Assert "added standard cost replaces the carried-forward cost" ($e.StillCarriedForward -eq 0) ""
    Assert "moved customer's sales follow its new region" ($e.MovedCustomerRowsNotMoved -eq 0) ""
    Assert "product rename reaches the dimension" ($e.RenamedProducts -eq 1) ""

    Write-Host "3. Full reload over the incremental result"
    $full = (Invoke-Query "EXEC etl.usp_LoadSales @FullReload = 1;").Rows[0]
    $afterFull = (Invoke-Query $checksumSql).Rows[0]
    $changes = $full.SalesInserted + $full.SalesUpdated + $full.SalesDeleted + $full.OrderLinesInserted + $full.OrderLinesUpdated + $full.OrderLinesDeleted
    Assert "full reload finds nothing the incremental missed" ($changes -eq 0) "$changes row change(s)"
    Assert "incremental reprocessed only part of the history" ($incremental.AffectedOrders -lt $full.AffectedOrders) `
        "$($incremental.AffectedOrders) of $($full.AffectedOrders) orders"
    foreach ($column in "SalesRows", "NetRevenue", "Cogs", "SalesChecksum", "OrderLineRows", "OrderLineChecksum") {
        Assert "checksum $column unchanged by the full reload" ($afterIncremental.$column -eq $afterFull.$column) "$($afterFull.$column)"
    }

    Write-Host "4. Incremental load with no new changes"
    $again = (Invoke-Query "EXEC etl.usp_LoadSales;").Rows[0]
    Assert "second incremental run is a no-op" ($again.AffectedOrders -eq 0) "affected orders $($again.AffectedOrders)"

    Write-Host "4b. Load started while another one holds the lock"
    $holder = New-Object System.Data.SqlClient.SqlConnection $connection.ConnectionString
    $holder.Open()
    $lock = $holder.CreateCommand()
    $lock.CommandText = "BEGIN TRANSACTION; EXEC sp_getapplock @Resource = N'etl.usp_LoadSales', @LockMode = 'Exclusive', @LockOwner = 'Transaction';"
    [void]$lock.ExecuteNonQuery()
    $refused = $false
    try { [void](Invoke-Query "EXEC etl.usp_LoadSales;") } catch { $refused = $_.Exception.Message -like "*in progress*" }
    $lock.CommandText = "ROLLBACK TRANSACTION;"   # releases the lock; Close alone would leave it on the pooled connection
    [void]$lock.ExecuteNonQuery()
    $holder.Close()
    $last = (Invoke-Query "SELECT TOP (1) Status, ErrorMessage FROM etl.LoadRun ORDER BY RunId DESC;").Rows[0]
    Assert "concurrent run is refused" $refused ""
    Assert "refused run is logged as failed" ($last.Status -eq "Failed") "$($last.ErrorMessage)"

    Write-Host "5. Restoring the database to the repository data"
    Reset-Database
    $restored = (Invoke-Query $checksumSql).Rows[0]
    $calendar = (Invoke-Query "SELECT MIN([Date]) AS FirstDate, MAX([Date]) AS LastDate FROM dw.DimDate;").Rows[0]
    Assert "restored facts match the starting point" ($restored.SalesChecksum -eq $before.SalesChecksum -and $restored.OrderLineChecksum -eq $before.OrderLineChecksum) ""
    Assert "calendar back to the source years" ($calendar.LastDate -eq [datetime]"2025-12-31") "$($calendar.FirstDate.ToString('yyyy-MM-dd')) to $($calendar.LastDate.ToString('yyyy-MM-dd'))"
}
finally {
    $connection.Close()
}

if ($failures -gt 0) { throw "$failures assertion(s) failed" }
Write-Host "All assertions passed"
