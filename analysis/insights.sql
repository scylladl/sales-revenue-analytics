/*
    Queries behind docs/06-insights.md (simulated data). Each section returns one result set.
    The budget lives only in the finance workbook (rule R7), so the budget gap is analysed in DAX
    (analysis/budget_gap.dax), not here. Estimates state their assumption in the column name.
*/
SET NOCOUNT ON;

/* 1. HoReCa discounts above the contract policy of the customer's tier, by region and year.
      Free samples (100 % discount) are a legitimate exception and are left out. */
SELECT YEAR(f.PostingDate) AS [Year], r.RegionName,
       CAST(SUM(f.DiscountAmount) / SUM(f.GrossSales) AS decimal(5,4)) AS DiscountRate,
       CAST(SUM(IIF(f.DiscountPct > p.MaxContractPct, 1.0, 0)) / COUNT(*) AS decimal(5,4)) AS LinesAbovePolicyShare,
       CAST(SUM(IIF(f.DiscountPct > p.MaxContractPct, f.GrossSales * (f.DiscountPct - p.MaxContractPct) / 100, 0)) AS decimal(12,0)) AS DiscountAbovePolicy
FROM dw.FactSales AS f
JOIN dw.DimCustomer AS c ON c.CustomerKey = f.CustomerKey
JOIN ref.DiscountPolicy AS p ON p.ChannelCode = c.ChannelCode AND p.Segment = c.Segment
JOIN ref.Region AS r ON r.RegionCode = f.RegionCode
WHERE f.LineType = 'Invoice' AND f.ChannelCode = 'HORECA' AND f.DiscountPct < 100
GROUP BY YEAR(f.PostingDate), r.RegionName, r.SortOrder
ORDER BY [Year], r.SortOrder;

/* 2. Retail raised coffee list prices in July 2025, five months after the other channels.
      Estimate: gross profit of Retail coffee orders placed February to June 2025 had their list price been 7 %
      higher, with the same volumes and discounts (cost does not change, so the whole difference is profit). */
SELECT CAST(SUM(f.GrossSales - f.DiscountAmount) AS decimal(12,0)) AS NetSalesFebToJun,
       CAST(SUM((f.GrossSales - f.DiscountAmount) * 0.07) AS decimal(12,0)) AS EstimatedProfitAtFebruaryIncrease
FROM dw.FactSales AS f
JOIN ref.Category AS cat ON cat.CategoryCode = f.CategoryCode
WHERE f.LineType = 'Invoice' AND f.ChannelCode = 'RETAIL' AND cat.IsCoffee = 1
  AND f.OrderDate >= '2025-02-01' AND f.OrderDate < '2025-07-01';

/* 3. Retail capsule promotions (days 1 to 10 of March, May, September and November) against the other days of
      the same months, by order date. */
WITH capsule AS (
    SELECT YEAR(f.OrderDate) AS [Year], f.OrderDate,
           IIF(DAY(f.OrderDate) <= 10, 'Promotion', 'Rest of month') AS Period,
           f.Quantity, f.GrossSales, f.DiscountAmount, f.GrossSales - f.DiscountAmount AS Net, f.Cogs
    FROM dw.FactSales AS f
    WHERE f.LineType = 'Invoice' AND f.ChannelCode = 'RETAIL' AND f.CategoryCode = 'CAPS'
      AND MONTH(f.OrderDate) IN (3, 5, 9, 11)
)
SELECT [Year], Period, COUNT(DISTINCT OrderDate) AS Days,
       CAST(SUM(Quantity) * 1.0 / COUNT(DISTINCT OrderDate) AS decimal(8,0)) AS UnitsPerDay,
       CAST(SUM(DiscountAmount) / SUM(GrossSales) AS decimal(5,4)) AS DiscountRate,
       CAST((SUM(Net) - SUM(Cogs)) / SUM(Net) AS decimal(5,4)) AS GrossMargin,
       CAST((SUM(Net) - SUM(Cogs)) / COUNT(DISTINCT OrderDate) AS decimal(10,0)) AS GrossProfitPerDay
FROM capsule
GROUP BY [Year], Period
ORDER BY [Year], Period;

/* 4. E-commerce equipment: share of channel revenue, margin, and returns attributed to the original sale */
SELECT YEAR(f.OriginalInvoiceDate) AS SaleYear,
       CAST(SUM(IIF(f.CategoryCode = 'EQUIP' AND f.LineType = 'Invoice', f.NetRevenue, 0))
            / SUM(IIF(f.LineType = 'Invoice', f.NetRevenue, 0)) AS decimal(5,4)) AS EquipmentShareOfSales,
       CAST(SUM(IIF(f.CategoryCode = 'EQUIP', f.NetRevenue - f.Cogs, 0)) / NULLIF(SUM(IIF(f.CategoryCode = 'EQUIP', f.NetRevenue, 0)), 0) AS decimal(5,4)) AS EquipmentMargin,
       CAST(SUM(IIF(f.CategoryCode <> 'EQUIP', f.NetRevenue - f.Cogs, 0)) / SUM(IIF(f.CategoryCode <> 'EQUIP', f.NetRevenue, 0)) AS decimal(5,4)) AS OtherMargin,
       CAST(SUM(IIF(f.CategoryCode = 'EQUIP', f.ReturnAmount, 0)) / NULLIF(SUM(IIF(f.CategoryCode = 'EQUIP', f.GrossSales - f.DiscountAmount, 0)), 0) AS decimal(5,4)) AS EquipmentReturnRate
FROM dw.FactSales AS f
WHERE f.ChannelCode = 'ECOM'
GROUP BY YEAR(f.OriginalInvoiceDate)
ORDER BY SaleYear;

/* 5. Gross margin by channel and year (after returns) */
SELECT YEAR(PostingDate) AS [Year], ChannelCode,
       CAST(SUM(NetRevenue) AS decimal(12,0)) AS NetRevenue,
       CAST((SUM(NetRevenue) - SUM(Cogs)) / SUM(NetRevenue) AS decimal(5,4)) AS GrossMargin
FROM dw.FactSales
GROUP BY YEAR(PostingDate), ChannelCode
ORDER BY ChannelCode, [Year];
