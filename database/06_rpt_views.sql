/*
    Step 06: views read by Power BI (schema rpt). The semantic model reads only these views, so dw can change
    without breaking the report as long as the view columns stay the same.
*/
USE VelmoraSales;
GO

CREATE OR ALTER VIEW rpt.vw_Date AS
SELECT [Date], [Year], [Quarter], CONCAT('Q', [Quarter]) AS QuarterLabel, MonthNumber, MonthName,
       LEFT(MonthName, 3) AS MonthShort, YearMonth, CONCAT(LEFT(MonthName, 3), ' ', [Year]) AS MonthLabel,
       MonthStart, IsoWeekday
FROM dw.DimDate;
GO
CREATE OR ALTER VIEW rpt.vw_Channel AS
SELECT ChannelCode, ChannelName, SortOrder FROM ref.Channel;
GO
CREATE OR ALTER VIEW rpt.vw_Region AS
SELECT RegionCode, RegionName, SortOrder FROM ref.Region;
GO
CREATE OR ALTER VIEW rpt.vw_Category AS
SELECT CategoryCode, CategoryName, IsCoffee, SortOrder FROM ref.Category;
GO
CREATE OR ALTER VIEW rpt.vw_Customer AS
SELECT c.CustomerKey, c.CustomerId, c.CustomerName, c.Segment, c.City, c.CreatedDate,
       CAST(IIF(EXISTS (SELECT 1 FROM dq.vw_PossibleDuplicateCustomer AS d
                        WHERE c.CustomerId IN (d.CustomerId, d.OtherCustomerId)), 1, 0) AS bit) AS IsPossibleDuplicate
FROM dw.DimCustomer AS c;
GO
CREATE OR ALTER VIEW rpt.vw_Product AS
SELECT ProductKey, ProductId, ProductName, PackSize, LaunchDate FROM dw.DimProduct;
GO
CREATE OR ALTER VIEW rpt.vw_Sales AS
SELECT OrderId, LineType, PostingDate, OriginalInvoiceDate, CustomerKey, ProductKey, ChannelCode, RegionCode,
       CategoryCode, CampaignCode, ReturnReason, Quantity, DiscountPct, GrossSales, DiscountAmount, ReturnAmount,
       NetRevenue, Cogs, IsCostCarriedForward, IsQuantityCapped, IsInvoiceBeforeOrder
FROM dw.FactSales;
GO
CREATE OR ALTER VIEW rpt.vw_OrderLine AS
SELECT OrderId, OrderDate, OrderStatus, CustomerKey, ProductKey, ChannelCode, RegionCode, CategoryCode,
       CampaignCode, Quantity, OrderValue
FROM dw.FactOrderLine;
GO
CREATE OR ALTER VIEW rpt.vw_DataQualityCheck AS
SELECT CheckCode, CheckType, CheckName, AffectedRows, UnhandledRows, Handling, Result, RunAt
FROM dq.CheckResult;
GO
CREATE OR ALTER VIEW rpt.vw_ProcessingStatus AS
SELECT s.RunId      AS LastSuccessRunId,
       s.Mode       AS LastSuccessMode,
       s.FinishedAt AS LastSuccessAt,
       (SELECT MAX(PostingDate) FROM dw.FactSales) AS DataAsOfDate,
       l.Status     AS LastRunStatus,
       l.StartedAt  AS LastRunStartedAt,
       l.ErrorMessage AS LastRunError
FROM (SELECT TOP (1) RunId, Mode, FinishedAt FROM etl.LoadRun WHERE Status = 'Succeeded' ORDER BY RunId DESC) AS s
CROSS JOIN (SELECT TOP (1) Status, StartedAt, ErrorMessage FROM etl.LoadRun ORDER BY RunId DESC) AS l;
GO
