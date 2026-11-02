/*
    Gross margin bridge between two years (business question 3: why did the margin fall?).

    Cells are product x channel. On invoice lines (before returns) the margin of a cell is 1 - unit cost / unit
    net price, and the unit net price is list price x (1 - discount rate). The change of the total margin splits
    exactly into:
      mix       the same cell margins, weighted by the new year's revenue shares
      cost      standard cost change, at the old net price
      list      list price change, at the old discount rate
      discount  discount rate change
      new/discontinued products (cells sold in only one of the two years)
      returns   change of the margin lost to returns (revenue reversed, coffee cost not reversed)
    Results in percentage points; the parts add up to the total change.
*/
DECLARE @FromYear int = 2023, @ToYear int = 2025;

WITH cell AS (
    SELECT YEAR(PostingDate) AS [Year], ProductKey, ChannelCode,
           SUM(Quantity) AS Units, SUM(GrossSales) AS Gross, SUM(DiscountAmount) AS Discounts,
           SUM(GrossSales - DiscountAmount) AS Net, SUM(Cogs) AS Cogs
    FROM dw.FactSales
    WHERE LineType = 'Invoice' AND YEAR(PostingDate) IN (@FromYear, @ToYear)
    GROUP BY YEAR(PostingDate), ProductKey, ChannelCode
),
pair AS (
    SELECT a.ProductKey, a.ChannelCode,
           a.Net / a.Units AS PriceA, a.Cogs / a.Units AS CostA, a.Gross / a.Units AS ListA, a.Discounts / a.Gross AS DiscA,
           b.Net / b.Units AS PriceB, b.Cogs / b.Units AS CostB, b.Gross / b.Units AS ListB, b.Discounts / b.Gross AS DiscB,
           a.Net AS NetA, b.Net AS NetB
    FROM cell AS a
    JOIN cell AS b ON b.ProductKey = a.ProductKey AND b.ChannelCode = a.ChannelCode AND b.[Year] = @ToYear
    WHERE a.[Year] = @FromYear AND a.Gross > 0 AND b.Gross > 0
),
weighted AS (
    SELECT p.*,
           p.NetA / SUM(p.NetA) OVER () AS ShareA,
           p.NetB / SUM(p.NetB) OVER () AS ShareB,
           1 - p.CostA / p.PriceA AS MarginA,
           p.ListB * (1 - p.DiscA) AS PriceAtOldDiscount
    FROM pair AS p
),
total AS (
    SELECT [Year], 1 - SUM(Cogs) / SUM(Net) AS MarginBeforeReturns
    FROM cell
    GROUP BY [Year]
),
after_returns AS (
    SELECT YEAR(PostingDate) AS [Year], (SUM(NetRevenue) - SUM(Cogs)) / SUM(NetRevenue) AS GrossMargin
    FROM dw.FactSales
    WHERE YEAR(PostingDate) IN (@FromYear, @ToYear)
    GROUP BY YEAR(PostingDate)
),
parts AS (
    SELECT SUM(ShareB * MarginA) - SUM(ShareA * MarginA) AS Mix,
           SUM(ShareB * (CostA - CostB) / PriceA) AS Cost,
           SUM(ShareB * CostB * (1 / PriceA - 1 / PriceAtOldDiscount)) AS List,
           SUM(ShareB * CostB * (1 / PriceAtOldDiscount - 1 / PriceB)) AS Discount,
           SUM(ShareA * MarginA) AS CommonMarginA
    FROM weighted
)
SELECT Part, CAST(Points * 100 AS decimal(6,2)) AS Pp
FROM (
    SELECT 1 AS Ord, 'Gross margin ' + CAST(@FromYear AS varchar(4)) AS Part, (SELECT GrossMargin FROM after_returns WHERE [Year] = @FromYear) AS Points
    UNION ALL SELECT 2, 'Mix (product x channel)', Mix FROM parts
    UNION ALL SELECT 3, 'Standard cost', Cost FROM parts
    UNION ALL SELECT 4, 'List price', List FROM parts
    UNION ALL SELECT 5, 'Discount rate', Discount FROM parts
    UNION ALL SELECT 6, 'New and discontinued products',
        (SELECT MarginBeforeReturns FROM total WHERE [Year] = @ToYear) - (SELECT MarginBeforeReturns FROM total WHERE [Year] = @FromYear)
        - (Mix + Cost + List + Discount) FROM parts
    UNION ALL SELECT 7, 'Returns',
        ((SELECT GrossMargin FROM after_returns WHERE [Year] = @ToYear) - (SELECT MarginBeforeReturns FROM total WHERE [Year] = @ToYear))
        - ((SELECT GrossMargin FROM after_returns WHERE [Year] = @FromYear) - (SELECT MarginBeforeReturns FROM total WHERE [Year] = @FromYear))
    UNION ALL SELECT 8, 'Gross margin ' + CAST(@ToYear AS varchar(4)), (SELECT GrossMargin FROM after_returns WHERE [Year] = @ToYear)
) AS bridge
ORDER BY Ord;
