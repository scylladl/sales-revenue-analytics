/*
    Independent calculation of the main KPIs from the ERP tables (src), used by validation/validate_kpis.ps1.

    It applies the approved rules (docs/01-business-requirements.md) directly to src, without dw or the load
    procedure, so a defect in either shows up as a difference against the Power BI measures.
    Amounts are rounded to cents per line, as the ERP does. Result: one row per year and channel ('ALL' = all
    channels) and KPI.
*/
SET NOCOUNT ON;

-- Promotion period of an order line (CR-03): inside a ref.Promotion window for its channel and category, or on the
-- other days of that month
SELECT l.OrderId, l.LineNumber,
       MAX(IIF(o.OrderDate BETWEEN pr.StartDate AND pr.EndDate, 'Promotion', 'Rest of month')) AS PromotionPeriod
INTO #PromotionLine
FROM src.SalesOrderLine AS l
JOIN src.SalesOrder AS o ON o.OrderId = l.OrderId
JOIN src.Product AS p ON p.ProductId = l.ProductId
JOIN ref.Promotion AS pr
  ON pr.ChannelCode = o.ChannelCode AND pr.CategoryCode = p.CategoryCode
 AND YEAR(pr.StartDate) = YEAR(o.OrderDate) AND MONTH(pr.StartDate) = MONTH(o.OrderDate)
GROUP BY l.OrderId, l.LineNumber;

-- R1, R2, R5: invoice lines on the invoice date, standard cost of the invoice month (latest earlier month if missing).
-- CR-01: lines of orders without a campaign, free samples excluded, against the contract maximum of the segment.
SELECT YEAR(i.InvoiceDate) AS [Year], o.ChannelCode, o.OrderId, o.OrderDate, l.Quantity, g.GrossSales,
       ROUND(g.GrossSales * l.DiscountPct / 100, 2) AS DiscountAmount,
       ROUND(l.Quantity * c.UnitCost, 2) AS Cogs,
       IIF(o.CampaignCode IS NULL AND l.DiscountPct < 100, 1, 0) AS IsPolicyChecked,
       IIF(o.CampaignCode IS NULL AND l.DiscountPct < 100 AND l.DiscountPct > pol.MaxContractPct,
           ROUND(g.GrossSales * (l.DiscountPct - pol.MaxContractPct) / 100, 2), 0) AS DiscountAbovePolicy,
       pl.PromotionPeriod
INTO #InvoiceLine
FROM src.Invoice AS i
JOIN src.SalesOrder AS o ON o.OrderId = i.OrderId
JOIN src.SalesOrderLine AS l ON l.OrderId = o.OrderId
JOIN src.Customer AS cu ON cu.CustomerId = o.CustomerId
JOIN ref.DiscountPolicy AS pol ON pol.ChannelCode = cu.ChannelCode AND pol.Segment = cu.Segment
LEFT JOIN #PromotionLine AS pl ON pl.OrderId = l.OrderId AND pl.LineNumber = l.LineNumber
CROSS APPLY (SELECT CAST(l.Quantity * l.UnitListPrice AS decimal(14,2)) AS GrossSales) AS g
CROSS APPLY (SELECT TOP (1) sc.UnitCost FROM src.StandardCost AS sc
             WHERE sc.ProductId = l.ProductId AND sc.YearMonth <= YEAR(i.InvoiceDate) * 100 + MONTH(i.InvoiceDate)
             ORDER BY sc.YearMonth DESC) AS c;

-- R4, R5: credit note lines in the credit note month, never more units than invoiced; non-food returns go back
-- to stock (cost reversed), food is written off. Each order line has at most one credit note line in this data;
-- the check below stops the script if that changes.
IF EXISTS (SELECT 1 FROM src.CreditNoteLine GROUP BY OrderId, LineNumber HAVING COUNT(*) > 1)
    THROW 50000, 'An order line has several credit note lines; extend the cap to cumulative quantities.', 1;

SELECT YEAR(cn.CreditDate) AS [Year], YEAR(i.InvoiceDate) AS SaleYear, o.ChannelCode, o.OrderDate, v.ReturnAmount,
       IIF(p.IsFood = 0, ROUND(q.Quantity * c.UnitCost, 2), 0) AS CogsReversed, pl.PromotionPeriod
INTO #ReturnLine
FROM src.CreditNoteLine AS cl
JOIN src.CreditNote AS cn ON cn.CreditNoteId = cl.CreditNoteId
JOIN src.Invoice AS i ON i.InvoiceId = cn.InvoiceId
JOIN src.SalesOrder AS o ON o.OrderId = i.OrderId
JOIN src.SalesOrderLine AS l ON l.OrderId = cl.OrderId AND l.LineNumber = cl.LineNumber
JOIN src.Product AS p ON p.ProductId = l.ProductId
LEFT JOIN #PromotionLine AS pl ON pl.OrderId = l.OrderId AND pl.LineNumber = l.LineNumber
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
           SUM(il.Quantity) AS UnitsSold, COUNT(DISTINCT il.OrderId) AS InvoicedOrders,
           SUM(il.DiscountAbovePolicy) AS DiscountAbovePolicy, SUM(il.IsPolicyChecked) AS CheckedLines,
           SUM(IIF(il.DiscountAbovePolicy > 0, 1, 0)) AS LinesAbovePolicy
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
-- CR-03: gross profit of invoice and return rows by posting year, per order day, inside and outside the windows
promotion_row AS (
    SELECT [Year], ChannelCode, OrderDate, PromotionPeriod, GrossSales - DiscountAmount - Cogs AS GrossProfit
    FROM #InvoiceLine WHERE PromotionPeriod IS NOT NULL
    UNION ALL
    SELECT [Year], ChannelCode, OrderDate, PromotionPeriod, -ReturnAmount + CogsReversed
    FROM #ReturnLine WHERE PromotionPeriod IS NOT NULL
),
promoted AS (
    SELECT s.[Year], s.ChannelCode,
           SUM(IIF(pr.PromotionPeriod = 'Promotion', pr.GrossProfit, 0))
             / NULLIF(COUNT(DISTINCT IIF(pr.PromotionPeriod = 'Promotion', pr.OrderDate, NULL)), 0) AS ProfitPerPromotionDay,
           SUM(IIF(pr.PromotionPeriod = 'Rest of month', pr.GrossProfit, 0))
             / NULLIF(COUNT(DISTINCT IIF(pr.PromotionPeriod = 'Rest of month', pr.OrderDate, NULL)), 0) AS ProfitPerOrdinaryDay
    FROM scope AS s
    JOIN promotion_row AS pr ON pr.[Year] = s.[Year] AND s.ChannelCode IN (pr.ChannelCode, 'ALL')
    GROUP BY s.[Year], s.ChannelCode
),
kpi AS (
    SELECT i.[Year], i.ChannelCode, i.GrossSales, i.Discounts, r.Returns,
           i.GrossSales - i.Discounts - r.Returns AS NetRevenue,
           i.InvoiceCogs - r.CogsReversed AS Cogs,
           i.UnitsSold, i.InvoicedOrders, r.ReturnsOfTheYearSales, o.Orders, o.CancelledOrders,
           i.DiscountAbovePolicy, i.CheckedLines, i.LinesAbovePolicy, pm.ProfitPerPromotionDay, pm.ProfitPerOrdinaryDay
    FROM invoiced AS i
    JOIN returned AS r ON r.[Year] = i.[Year] AND r.ChannelCode = i.ChannelCode
    JOIN ordered AS o ON o.[Year] = i.[Year] AND o.ChannelCode = i.ChannelCode
    LEFT JOIN promoted AS pm ON pm.[Year] = i.[Year] AND pm.ChannelCode = i.ChannelCode
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
    ('Cancelled Orders', k.CancelledOrders),
    ('Discount Above Policy', k.DiscountAbovePolicy),
    ('Lines Above Policy %', CAST(k.LinesAbovePolicy AS float) / k.CheckedLines),
    ('Gross Profit per Promotion Day', k.ProfitPerPromotionDay),
    ('Gross Profit per Ordinary Day', k.ProfitPerOrdinaryDay)
) AS v (Kpi, Value)
ORDER BY k.[Year], k.ChannelCode, v.Kpi;
