/*
    Step 05: data quality checks (schema dq), run after every load.

    Two kinds of check:
      - Source:    defects in the ERP exports. The check passes when every affected row is handled by the
                   documented load rule (docs/03-data-model.md, "Source defects").
      - Integrity: properties dw must always have. Any affected row is a defect.

    Usage:  EXEC dq.usp_RunChecks;
*/
USE VelmoraSales;
GO

IF OBJECT_ID(N'dq.CheckResult') IS NULL
CREATE TABLE dq.CheckResult (
    CheckCode      varchar(10)    NOT NULL CONSTRAINT PK_CheckResult PRIMARY KEY,
    CheckType      varchar(10)    NOT NULL,   -- Source, Integrity
    CheckName      nvarchar(120)  NOT NULL,
    AffectedRows   int            NOT NULL,
    UnhandledRows  int            NOT NULL,
    Handling       nvarchar(300)  NOT NULL,
    Result         varchar(4)     NOT NULL,   -- Pass, Fail
    RunAt          datetime2(0)   NOT NULL
);
GO

-- Customers of the same channel with the same name and city under two ids. Merging them needs a business
-- decision (which id survives, how history moves), so they are listed for review.
CREATE OR ALTER VIEW dq.vw_PossibleDuplicateCustomer
AS
SELECT a.ChannelCode, a.CustomerName, a.City,
       a.CustomerId, a.CreatedDate,
       b.CustomerId  AS OtherCustomerId,
       b.CreatedDate AS OtherCreatedDate
FROM src.Customer AS a
JOIN src.Customer AS b
  ON b.ChannelCode = a.ChannelCode
 AND b.CustomerName = a.CustomerName
 AND b.City = a.City
 AND b.CustomerId > a.CustomerId;
GO

-- Product-months with invoiced lines and no standard cost
CREATE OR ALTER VIEW dq.vw_MissingStandardCost
AS
SELECT l.ProductId, m.YearMonth, COUNT(*) AS InvoiceLines
FROM src.Invoice AS i
JOIN src.SalesOrderLine AS l ON l.OrderId = i.OrderId
CROSS APPLY (SELECT YEAR(i.InvoiceDate) * 100 + MONTH(i.InvoiceDate) AS YearMonth) AS m
WHERE NOT EXISTS (SELECT 1 FROM src.StandardCost AS sc WHERE sc.ProductId = l.ProductId AND sc.YearMonth = m.YearMonth)
GROUP BY l.ProductId, m.YearMonth;
GO

-- Order lines credited for more units than were invoiced
CREATE OR ALTER VIEW dq.vw_ReturnAboveInvoiced
AS
SELECT cl.OrderId, cl.LineNumber, l.Quantity AS InvoicedQuantity, SUM(cl.Quantity) AS CreditedQuantity
FROM src.CreditNoteLine AS cl
JOIN src.SalesOrderLine AS l ON l.OrderId = cl.OrderId AND l.LineNumber = cl.LineNumber
GROUP BY cl.OrderId, cl.LineNumber, l.Quantity
HAVING SUM(cl.Quantity) > l.Quantity;
GO

CREATE OR ALTER VIEW dq.vw_InvoiceBeforeOrder
AS
SELECT i.InvoiceId, i.OrderId, o.OrderDate, i.InvoiceDate
FROM src.Invoice AS i
JOIN src.SalesOrder AS o ON o.OrderId = i.OrderId
WHERE i.InvoiceDate < o.OrderDate;
GO

CREATE OR ALTER PROCEDURE dq.usp_RunChecks
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now datetime2(0) = SYSDATETIME();
    DECLARE @r TABLE (CheckCode varchar(10), CheckType varchar(10), CheckName nvarchar(120),
                      AffectedRows int, UnhandledRows int, Handling nvarchar(300));

    /* ---------- source checks ---------- */
    INSERT INTO @r
    SELECT 'SRC-01', 'Source', N'Possible duplicate customers (same channel, name and city)',
           (SELECT COUNT(*) FROM dq.vw_PossibleDuplicateCustomer), 0,
           N'Kept as separate customers and listed in dq.vw_PossibleDuplicateCustomer for the sales team to review';

    INSERT INTO @r
    SELECT 'SRC-02', 'Source', N'Product-months invoiced without a standard cost',
           (SELECT COUNT(*) FROM dq.vw_MissingStandardCost),
           (SELECT COUNT(*)
            FROM dw.FactSales AS f
            JOIN dw.DimProduct AS p ON p.ProductKey = f.ProductKey
            JOIN dq.vw_MissingStandardCost AS m
              ON m.ProductId = p.ProductId AND m.YearMonth = YEAR(f.OriginalInvoiceDate) * 100 + MONTH(f.OriginalInvoiceDate)
            WHERE f.IsCostCarriedForward = 0),
           N'Costed with the latest earlier standard cost of the product and flagged IsCostCarriedForward';

    INSERT INTO @r
    SELECT 'SRC-03', 'Source', N'Order lines credited for more units than invoiced',
           (SELECT COUNT(*) FROM dq.vw_ReturnAboveInvoiced),
           (SELECT COUNT(*)
            FROM (SELECT OrderId, OrderLineNumber,
                         SUM(IIF(LineType = 'Invoice', Quantity, 0)) AS Invoiced,
                         -SUM(IIF(LineType = 'Return', Quantity, 0)) AS Returned
                  FROM dw.FactSales
                  GROUP BY OrderId, OrderLineNumber) AS x
            WHERE x.Returned > x.Invoiced),
           N'Returned quantity capped at the invoiced quantity and flagged IsQuantityCapped';

    INSERT INTO @r
    SELECT 'SRC-04', 'Source', N'Invoices dated before their order',
           (SELECT COUNT(*) FROM dq.vw_InvoiceBeforeOrder),
           (SELECT COUNT(DISTINCT v.InvoiceId)
            FROM dq.vw_InvoiceBeforeOrder AS v
            JOIN dw.FactSales AS f ON f.DocumentId = v.InvoiceId
            WHERE f.IsInvoiceBeforeOrder = 0 OR f.PostingDate <> v.InvoiceDate),
           N'Invoice date kept as the revenue date (rule R1) and flagged IsInvoiceBeforeOrder';

    INSERT INTO @r
    SELECT 'SRC-05', 'Source', N'Customers without region',
           (SELECT COUNT(*) FROM src.Customer WHERE RegionCode IS NULL),
           (SELECT COUNT(*)
            FROM src.Customer AS s
            JOIN dw.DimCustomer AS d ON d.CustomerId = s.CustomerId
            WHERE s.RegionCode IS NULL AND d.RegionCode <> 'UNK'),
           N'Region Unknown (UNK); their sales count in every total and in no regional budget';

    /* ---------- integrity checks ---------- */
    INSERT INTO @r
    SELECT 'INT-01', 'Integrity', N'Invoice lines missing from dw or not in the source', x.n, x.n,
           N'Every invoiced order line is one Invoice row in dw.FactSales'
    FROM (SELECT (SELECT COUNT(*)
                  FROM src.Invoice AS i
                  JOIN src.SalesOrderLine AS l ON l.OrderId = i.OrderId
                  WHERE NOT EXISTS (SELECT 1 FROM dw.FactSales AS f
                                    WHERE f.DocumentId = i.InvoiceId AND f.DocumentLine = l.LineNumber))
               + (SELECT COUNT(*)
                  FROM dw.FactSales AS f
                  WHERE f.LineType = 'Invoice'
                    AND NOT EXISTS (SELECT 1 FROM src.Invoice AS i
                                    JOIN src.SalesOrderLine AS l ON l.OrderId = i.OrderId
                                    WHERE i.InvoiceId = f.DocumentId AND l.LineNumber = f.DocumentLine)) AS n) AS x;

    INSERT INTO @r
    SELECT 'INT-02', 'Integrity', N'Credit note lines missing from dw or not in the source', x.n, x.n,
           N'Every credit note line is one Return row in dw.FactSales'
    FROM (SELECT (SELECT COUNT(*)
                  FROM src.CreditNoteLine AS cl
                  WHERE NOT EXISTS (SELECT 1 FROM dw.FactSales AS f
                                    WHERE f.DocumentId = cl.CreditNoteId AND f.DocumentLine = cl.CreditLineNumber))
               + (SELECT COUNT(*)
                  FROM dw.FactSales AS f
                  WHERE f.LineType = 'Return'
                    AND NOT EXISTS (SELECT 1 FROM src.CreditNoteLine AS cl
                                    WHERE cl.CreditNoteId = f.DocumentId AND cl.CreditLineNumber = f.DocumentLine)) AS n) AS x;

    INSERT INTO @r
    SELECT 'INT-03', 'Integrity', N'Order lines missing from dw or not in the source', x.n, x.n,
           N'Every order line, whatever its status, is one row in dw.FactOrderLine'
    FROM (SELECT (SELECT COUNT(*)
                  FROM src.SalesOrderLine AS l
                  WHERE NOT EXISTS (SELECT 1 FROM dw.FactOrderLine AS f
                                    WHERE f.OrderId = l.OrderId AND f.LineNumber = l.LineNumber))
               + (SELECT COUNT(*)
                  FROM dw.FactOrderLine AS f
                  WHERE NOT EXISTS (SELECT 1 FROM src.SalesOrderLine AS l
                                    WHERE l.OrderId = f.OrderId AND l.LineNumber = f.LineNumber)) AS n) AS x;

    INSERT INTO @r
    SELECT 'INT-04', 'Integrity', N'Revenue rows for orders that are not invoiced', x.n, x.n,
           N'Cancelled and open orders never become revenue (rule R3)'
    FROM (SELECT COUNT(*) AS n
          FROM dw.FactSales AS f
          JOIN src.SalesOrder AS o ON o.OrderId = f.OrderId
          WHERE o.Status <> 'Invoiced') AS x;

    INSERT INTO @r
    SELECT 'INT-05', 'Integrity', N'Order lines whose returns exceed their invoiced value', x.n, x.n,
           N'Net revenue of an order line never goes below zero'
    FROM (SELECT COUNT(*) AS n
          FROM (SELECT OrderId, OrderLineNumber
                FROM dw.FactSales
                GROUP BY OrderId, OrderLineNumber
                HAVING SUM(NetRevenue) < 0) AS l) AS x;

    BEGIN TRANSACTION;
    DELETE FROM dq.CheckResult;
    INSERT INTO dq.CheckResult (CheckCode, CheckType, CheckName, AffectedRows, UnhandledRows, Handling, Result, RunAt)
    SELECT CheckCode, CheckType, CheckName, AffectedRows, UnhandledRows, Handling,
           CASE WHEN UnhandledRows = 0 THEN 'Pass' ELSE 'Fail' END, @Now
    FROM @r;
    COMMIT TRANSACTION;

    SELECT CheckCode, CheckType, CheckName, AffectedRows, UnhandledRows, Result
    FROM dq.CheckResult
    ORDER BY CheckCode;
END;
GO
