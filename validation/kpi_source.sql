/*
    Independent calculation of the main KPIs from the ERP tables (src), used by validation/validate_kpis.ps1.

    It applies the approved rules (docs/01-business-requirements.md) directly to src, without dw or the load
    procedure, so a defect in either shows up as a difference against the Power BI measures.
    Amounts are rounded to cents per line, as the ERP does. Result: one row per year and channel ('ALL' = all
    channels) and KPI.
*/
SET NOCOUNT ON;

-- R1, R2, R5: invoice lines on the invoice date, standard cost of the invoice month (latest earlier month if missing)
SELECT YEAR(i.InvoiceDate) AS [Year], o.ChannelCode, o.OrderId, l.Quantity, g.GrossSales,
       ROUND(g.GrossSales * l.DiscountPct / 100, 2) AS DiscountAmount,
       ROUND(l.Quantity * c.UnitCost, 2) AS Cogs
INTO #InvoiceLine
FROM src.Invoice AS i
JOIN src.SalesOrder AS o ON o.OrderId = i.OrderId
JOIN src.SalesOrderLine AS l ON l.OrderId = o.OrderId
CROSS APPLY (SELECT CAST(l.Quantity * l.UnitListPrice AS decimal(14,2)) AS GrossSales) AS g
CROSS APPLY (SELECT TOP (1) sc.UnitCost FROM src.StandardCost AS sc
             WHERE sc.ProductId = l.ProductId AND sc.YearMonth <= YEAR(i.InvoiceDate) * 100 + MONTH(i.InvoiceDate)
             ORDER BY sc.YearMonth DESC) AS c;

-- R4, R5: credit note lines in the credit note month, never more units than invoiced; non-food returns go back
-- to stock (cost reversed), food is written off. Each order line has at most one credit note line in this data;
-- the check below stops the script if that changes.
IF EXISTS (SELECT 1 FROM src.CreditNoteLine GROUP BY OrderId, LineNumber HAVING COUNT(*) > 1)
    THROW 50000, 'An order line has several credit note lines; extend the cap to cumulative quantities.', 1;

SELECT YEAR(cn.CreditDate) AS [Year], YEAR(i.InvoiceDate) AS SaleYear, o.ChannelCode, v.ReturnAmount,
       IIF(p.IsFood = 0, ROUND(q.Quantity * c.UnitCost, 2), 0) AS CogsReversed
INTO #ReturnLine
FROM src.CreditNoteLine AS cl
JOIN src.CreditNote AS cn ON cn.CreditNoteId = cl.CreditNoteId
JOIN src.Invoice AS i ON i.InvoiceId = cn.InvoiceId
JOIN src.SalesOrder AS o ON o.OrderId = i.OrderId
JOIN src.SalesOrderLine AS l ON l.OrderId = cl.OrderId AND l.LineNumber = cl.LineNumber
JOIN src.Product AS p ON p.ProductId = l.ProductId
CROSS APPLY (SELECT IIF(cl.Quantity < l.Quantity, cl.Quantity, l.Quantity) AS Quantity) AS q
CROSS APPLY (SELECT CAST(q.Quantity * l.UnitListPrice AS decimal(14,2)) AS Gross) AS g
CROSS APPLY (SELECT g.Gross - ROUND(g.Gross * l.DiscountPct / 100, 2) AS ReturnAmount) AS v
CROSS APPLY (SELECT TOP (1) sc.UnitCost FROM src.StandardCost AS sc
             WHERE sc.ProductId = l.ProductId AND sc.YearMonth <= YEAR(i.InvoiceDate) * 100 + MONTH(i.InvoiceDate)
             ORDER BY sc.YearMonth DESC) AS c;

WITH scope AS (
    SELECT DISTINCT [Year], ChannelCode FROM #InvoiceLine
    UNION
    SELECT DISTINCT [Year], 'ALL' FROM #InvoiceLine
),
invoiced AS (
    SELECT s.[Year], s.ChannelCode,
           SUM(il.GrossSales) AS GrossSales, SUM(il.DiscountAmount) AS Discounts, SUM(il.Cogs) AS InvoiceCogs,
           SUM(il.Quantity) AS UnitsSold, COUNT(DISTINCT il.OrderId) AS InvoicedOrders
    FROM scope AS s
    JOIN #InvoiceLine AS il ON il.[Year] = s.[Year] AND s.ChannelCode IN (il.ChannelCode, 'ALL')
    GROUP BY s.[Year], s.ChannelCode
),
returned AS (
    SELECT s.[Year], s.ChannelCode,
           SUM(IIF(r.[Year] = s.[Year], r.ReturnAmount, 0)) AS Returns,
           SUM(IIF(r.[Year] = s.[Year], r.CogsReversed, 0)) AS CogsReversed,
           SUM(IIF(r.SaleYear = s.[Year], r.ReturnAmount, 0)) AS ReturnsOfTheYearSales
    FROM scope AS s
    JOIN #ReturnLine AS r ON s.[Year] IN (r.[Year], r.SaleYear) AND s.ChannelCode IN (r.ChannelCode, 'ALL')
    GROUP BY s.[Year], s.ChannelCode
),
ordered AS (
    SELECT s.[Year], s.ChannelCode, COUNT(*) AS Orders, SUM(IIF(o.Status = 'Cancelled', 1, 0)) AS CancelledOrders
    FROM scope AS s
    JOIN src.SalesOrder AS o ON YEAR(o.OrderDate) = s.[Year] AND s.ChannelCode IN (o.ChannelCode, 'ALL')
    GROUP BY s.[Year], s.ChannelCode
),
kpi AS (
    SELECT i.[Year], i.ChannelCode, i.GrossSales, i.Discounts, r.Returns,
           i.GrossSales - i.Discounts - r.Returns AS NetRevenue,
           i.InvoiceCogs - r.CogsReversed AS Cogs,
           i.UnitsSold, i.InvoicedOrders, r.ReturnsOfTheYearSales, o.Orders, o.CancelledOrders
    FROM invoiced AS i
    JOIN returned AS r ON r.[Year] = i.[Year] AND r.ChannelCode = i.ChannelCode
    JOIN ordered AS o ON o.[Year] = i.[Year] AND o.ChannelCode = i.ChannelCode
)
SELECT k.[Year], k.ChannelCode, v.Kpi, v.Value
FROM kpi AS k
CROSS APPLY (VALUES
    ('Gross Sales', CAST(k.GrossSales AS float)),
    ('Discounts', k.Discounts),
    ('Returns', k.Returns),
    ('Net Revenue', k.NetRevenue),
    ('COGS', k.Cogs),
    ('Gross Profit', k.NetRevenue - k.Cogs),
    ('Gross Margin %', (k.NetRevenue - k.Cogs) / k.NetRevenue),
    ('Discount Rate %', k.Discounts / k.GrossSales),
    ('Return Rate %', k.ReturnsOfTheYearSales / (k.GrossSales - k.Discounts)),
    ('Units Sold', k.UnitsSold),
    ('Invoiced Orders', k.InvoicedOrders),
    ('Average Order Value', IIF(k.ChannelCode = 'ALL', NULL, k.NetRevenue / k.InvoicedOrders)),
    ('Orders', k.Orders),
    ('Cancelled Orders', k.CancelledOrders)
) AS v (Kpi, Value)
ORDER BY k.[Year], k.ChannelCode, v.Kpi;
