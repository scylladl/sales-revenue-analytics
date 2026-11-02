/*
    Step 04: etl.usp_LoadSales, the scheduled load from src to dw.

    Incremental by default. Each source table has a watermark (etl.Watermark, last ModifiedAt processed).
    An order is reprocessed when anything that feeds its fact rows changed since the last run: the order, its lines,
    its invoice, its credit notes, its customer, one of its products, or the standard cost of one of its products
    for the invoice month or an earlier month (a missing month carries the earlier cost forward).
    The fact rows of every affected order are rebuilt with MERGE: inserted, updated when a value differs, deleted
    when the source no longer has them. Running the procedure twice in a row changes nothing the second time.

    @FullReload = 1 resets the watermarks and reprocesses every order, including fact rows whose order is gone.
    The whole run is one transaction, under an application lock so two loads never overlap. Each run is
    recorded in etl.LoadRun, failures included.

    Assumption: the ERP never hard-deletes orders, customers or products (it cancels or deactivates them).
    Reference tables (ref) carry no timestamps: after a change to the discount policy or the promotion calendar,
    run a full reload.
*/
USE VelmoraSales;
GO

CREATE OR ALTER PROCEDURE etl.usp_LoadSales
    @FullReload bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RunId int;
    INSERT etl.LoadRun (Mode, StartedAt, Status)
    VALUES (IIF(@FullReload = 1, 'Full', 'Incremental'), SYSDATETIME(), 'Running');
    SET @RunId = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Lock int;
        EXEC @Lock = sp_getapplock @Resource = N'etl.usp_LoadSales', @LockMode = 'Exclusive',
                                   @LockOwner = 'Transaction', @LockTimeout = 0;
        IF @Lock < 0
            THROW 50001, 'Another run of etl.usp_LoadSales is in progress.', 1;

        IF @FullReload = 1
            UPDATE etl.Watermark SET LastModifiedAt = '1900-01-01';

        DECLARE @Customer datetime2(0), @Product datetime2(0), @StandardCost datetime2(0), @SalesOrder datetime2(0),
                @SalesOrderLine datetime2(0), @Invoice datetime2(0), @CreditNote datetime2(0), @CreditNoteLine datetime2(0);
        SELECT @Customer       = MAX(IIF(SourceTable = N'src.Customer', LastModifiedAt, NULL)),
               @Product        = MAX(IIF(SourceTable = N'src.Product', LastModifiedAt, NULL)),
               @StandardCost   = MAX(IIF(SourceTable = N'src.StandardCost', LastModifiedAt, NULL)),
               @SalesOrder     = MAX(IIF(SourceTable = N'src.SalesOrder', LastModifiedAt, NULL)),
               @SalesOrderLine = MAX(IIF(SourceTable = N'src.SalesOrderLine', LastModifiedAt, NULL)),
               @Invoice        = MAX(IIF(SourceTable = N'src.Invoice', LastModifiedAt, NULL)),
               @CreditNote     = MAX(IIF(SourceTable = N'src.CreditNote', LastModifiedAt, NULL)),
               @CreditNoteLine = MAX(IIF(SourceTable = N'src.CreditNoteLine', LastModifiedAt, NULL))
        FROM etl.Watermark;

        -- New watermarks are taken before reading the changes: a row written during the run is read again next time
        SELECT SourceTable, NewModifiedAt
        INTO #NewWatermark
        FROM (VALUES (N'src.Customer',       (SELECT MAX(ModifiedAt) FROM src.Customer)),
                     (N'src.Product',        (SELECT MAX(ModifiedAt) FROM src.Product)),
                     (N'src.StandardCost',   (SELECT MAX(ModifiedAt) FROM src.StandardCost)),
                     (N'src.SalesOrder',     (SELECT MAX(ModifiedAt) FROM src.SalesOrder)),
                     (N'src.SalesOrderLine', (SELECT MAX(ModifiedAt) FROM src.SalesOrderLine)),
                     (N'src.Invoice',        (SELECT MAX(ModifiedAt) FROM src.Invoice)),
                     (N'src.CreditNote',     (SELECT MAX(ModifiedAt) FROM src.CreditNote)),
                     (N'src.CreditNoteLine', (SELECT MAX(ModifiedAt) FROM src.CreditNoteLine))) AS w (SourceTable, NewModifiedAt);

        /* Dimensions */

        MERGE dw.DimCustomer AS t
        USING (SELECT CustomerId, CustomerName, ChannelCode, Segment, COALESCE(RegionCode, 'UNK') AS RegionCode, City, CreatedDate
               FROM src.Customer
               WHERE ModifiedAt > @Customer) AS s
           ON t.CustomerId = s.CustomerId
        WHEN MATCHED AND EXISTS (SELECT s.CustomerName, s.ChannelCode, s.Segment, s.RegionCode, s.City, s.CreatedDate
                                 EXCEPT
                                 SELECT t.CustomerName, t.ChannelCode, t.Segment, t.RegionCode, t.City, t.CreatedDate) THEN
            UPDATE SET CustomerName = s.CustomerName, ChannelCode = s.ChannelCode, Segment = s.Segment,
                       RegionCode = s.RegionCode, City = s.City, CreatedDate = s.CreatedDate
        WHEN NOT MATCHED THEN
            INSERT (CustomerId, CustomerName, ChannelCode, Segment, RegionCode, City, CreatedDate)
            VALUES (s.CustomerId, s.CustomerName, s.ChannelCode, s.Segment, s.RegionCode, s.City, s.CreatedDate);

        MERGE dw.DimProduct AS t
        USING (SELECT ProductId, ProductName, CategoryCode, PackSize, LaunchDate
               FROM src.Product
               WHERE ModifiedAt > @Product) AS s
           ON t.ProductId = s.ProductId
        WHEN MATCHED AND EXISTS (SELECT s.ProductName, s.CategoryCode, s.PackSize, s.LaunchDate
                                 EXCEPT
                                 SELECT t.ProductName, t.CategoryCode, t.PackSize, t.LaunchDate) THEN
            UPDATE SET ProductName = s.ProductName, CategoryCode = s.CategoryCode, PackSize = s.PackSize,
                       LaunchDate = s.LaunchDate
        WHEN NOT MATCHED THEN
            INSERT (ProductId, ProductName, CategoryCode, PackSize, LaunchDate)
            VALUES (s.ProductId, s.ProductName, s.CategoryCode, s.PackSize, s.LaunchDate);

        -- Calendar: whole years covering every order, invoice and credit note date
        DECLARE @FirstDate date, @LastDate date;
        SELECT @FirstDate = DATEFROMPARTS(YEAR(MIN(d)), 1, 1), @LastDate = DATEFROMPARTS(YEAR(MAX(d)), 12, 31)
        FROM (SELECT OrderDate FROM src.SalesOrder
              UNION ALL SELECT InvoiceDate FROM src.Invoice
              UNION ALL SELECT CreditDate FROM src.CreditNote) AS x (d);

        INSERT dw.DimDate ([Date], [Year], [Quarter], MonthNumber, MonthName, YearMonth, MonthStart, DayOfMonth, IsoWeekday)
        SELECT d.[Date], YEAR(d.[Date]), DATEPART(quarter, d.[Date]), MONTH(d.[Date]),
               CHOOSE(MONTH(d.[Date]), 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
                      'September', 'October', 'November', 'December'),
               YEAR(d.[Date]) * 100 + MONTH(d.[Date]), DATEFROMPARTS(YEAR(d.[Date]), MONTH(d.[Date]), 1), DAY(d.[Date]),
               DATEDIFF(day, '19000101', d.[Date]) % 7 + 1   -- 1900-01-01 was a Monday; independent of SET DATEFIRST
        FROM GENERATE_SERIES(0, DATEDIFF(day, @FirstDate, @LastDate)) AS g
        CROSS APPLY (SELECT DATEADD(day, g.value, @FirstDate) AS [Date]) AS d
        WHERE NOT EXISTS (SELECT 1 FROM dw.DimDate AS dd WHERE dd.[Date] = d.[Date]);

        /* Orders to reprocess */

        CREATE TABLE #AffectedOrder (OrderId varchar(9) NOT NULL PRIMARY KEY);
        INSERT #AffectedOrder (OrderId)
        SELECT OrderId FROM src.SalesOrder WHERE ModifiedAt > @SalesOrder
        UNION SELECT OrderId FROM src.SalesOrderLine WHERE ModifiedAt > @SalesOrderLine
        UNION SELECT OrderId FROM src.Invoice WHERE ModifiedAt > @Invoice
        UNION SELECT i.OrderId FROM src.CreditNote AS cn JOIN src.Invoice AS i ON i.InvoiceId = cn.InvoiceId
              WHERE cn.ModifiedAt > @CreditNote
        UNION SELECT OrderId FROM src.CreditNoteLine WHERE ModifiedAt > @CreditNoteLine
        UNION SELECT o.OrderId FROM src.SalesOrder AS o JOIN src.Customer AS c ON c.CustomerId = o.CustomerId
              WHERE c.ModifiedAt > @Customer
        UNION SELECT l.OrderId FROM src.SalesOrderLine AS l JOIN src.Product AS p ON p.ProductId = l.ProductId
              WHERE p.ModifiedAt > @Product
        UNION SELECT l.OrderId
              FROM src.StandardCost AS sc
              JOIN src.SalesOrderLine AS l ON l.ProductId = sc.ProductId
              JOIN src.Invoice AS i ON i.OrderId = l.OrderId
              WHERE sc.ModifiedAt > @StandardCost AND YEAR(i.InvoiceDate) * 100 + MONTH(i.InvoiceDate) >= sc.YearMonth
        -- a full reload also visits orders that only exist in dw, so their rows are removed
        UNION SELECT OrderId FROM dw.FactOrderLine WHERE @FullReload = 1
        UNION SELECT OrderId FROM dw.FactSales WHERE @FullReload = 1;

        /* Order lines of the affected orders, priced and costed (rules R2, R5) */

        SELECT o.OrderId, l.LineNumber, o.OrderDate, o.Status, CAST(o.CancelledAt AS date) AS CancelledDate,
               i.InvoiceId, i.InvoiceDate, o.ChannelCode, o.CampaignCode,
               c.CustomerKey, c.RegionCode, p.ProductKey, p.CategoryCode, cat.IsRestockable,
               l.Quantity, l.UnitListPrice, l.DiscountPct, amount.GrossSales,
               CAST(ROUND(amount.GrossSales * l.DiscountPct / 100, 2) AS decimal(14,2)) AS DiscountAmount,
               cost.UnitCost,
               CAST(IIF(cost.YearMonth < YEAR(i.InvoiceDate) * 100 + MONTH(i.InvoiceDate), 1, 0) AS bit) AS IsCostCarriedForward,
               policy.MaxContractPct, promo.PromotionPeriod
        INTO #Line
        FROM #AffectedOrder AS a
        JOIN src.SalesOrder AS o ON o.OrderId = a.OrderId
        JOIN src.SalesOrderLine AS l ON l.OrderId = o.OrderId
        JOIN dw.DimCustomer AS c ON c.CustomerId = o.CustomerId
        JOIN dw.DimProduct AS p ON p.ProductId = l.ProductId
        JOIN ref.Category AS cat ON cat.CategoryCode = p.CategoryCode
        LEFT JOIN src.Invoice AS i ON i.OrderId = o.OrderId
        CROSS APPLY (SELECT CAST(l.Quantity * l.UnitListPrice AS decimal(14,2)) AS GrossSales) AS amount
        OUTER APPLY (SELECT TOP (1) sc.UnitCost, sc.YearMonth
                     FROM src.StandardCost AS sc
                     WHERE sc.ProductId = l.ProductId
                       AND sc.YearMonth <= YEAR(i.InvoiceDate) * 100 + MONTH(i.InvoiceDate)
                     ORDER BY sc.YearMonth DESC) AS cost
        LEFT JOIN ref.DiscountPolicy AS policy ON policy.ChannelCode = c.ChannelCode AND policy.Segment = c.Segment
        -- a month with a promotion for the line's channel and category: inside the window or on the other days
        OUTER APPLY (SELECT TOP (1) CAST(IIF(o.OrderDate BETWEEN pr.StartDate AND pr.EndDate, 'Promotion', 'Rest of month') AS varchar(13)) AS PromotionPeriod
                     FROM ref.Promotion AS pr
                     WHERE pr.ChannelCode = o.ChannelCode AND pr.CategoryCode = p.CategoryCode
                       AND DATEFROMPARTS(YEAR(pr.StartDate), MONTH(pr.StartDate), 1) = DATEFROMPARTS(YEAR(o.OrderDate), MONTH(o.OrderDate), 1)
                     ORDER BY IIF(o.OrderDate BETWEEN pr.StartDate AND pr.EndDate, 0, 1)) AS promo;

        /* Sales rows: invoice lines and credit note lines (rules R1, R3, R4) */

        WITH credit AS (
            SELECT cl.CreditNoteId, cl.CreditLineNumber, cl.OrderId, cl.LineNumber, cl.Quantity, cn.CreditDate, cn.Reason,
                   SUM(cl.Quantity) OVER (PARTITION BY cl.OrderId, cl.LineNumber
                                          ORDER BY cn.CreditDate, cl.CreditNoteId, cl.CreditLineNumber
                                          ROWS UNBOUNDED PRECEDING) AS CumulativeQuantity
            FROM src.CreditNoteLine AS cl
            JOIN src.CreditNote AS cn ON cn.CreditNoteId = cl.CreditNoteId
            WHERE EXISTS (SELECT 1 FROM #AffectedOrder AS a WHERE a.OrderId = cl.OrderId)
        ),
        returned AS (
            -- what was returned in total never exceeds what was invoiced on the line
            SELECT cr.*, ln.InvoiceId, ln.InvoiceDate, ln.OrderDate, ln.CustomerKey, ln.ProductKey, ln.ChannelCode,
                   ln.RegionCode, ln.CategoryCode, ln.CampaignCode, ln.IsRestockable, ln.UnitListPrice, ln.DiscountPct,
                   ln.UnitCost, ln.IsCostCarriedForward, ln.PromotionPeriod,
                   IIF(cr.CumulativeQuantity < ln.Quantity, cr.CumulativeQuantity, ln.Quantity)
                     - IIF(cr.CumulativeQuantity - cr.Quantity < ln.Quantity, cr.CumulativeQuantity - cr.Quantity, ln.Quantity)
                     AS ReturnedQuantity
            FROM credit AS cr
            JOIN #Line AS ln ON ln.OrderId = cr.OrderId AND ln.LineNumber = cr.LineNumber
        )
        SELECT InvoiceId AS DocumentId, LineNumber AS DocumentLine, CAST('Invoice' AS varchar(7)) AS LineType,
               OrderId, LineNumber AS OrderLineNumber, InvoiceId, InvoiceDate AS PostingDate, InvoiceDate AS OriginalInvoiceDate,
               OrderDate, CustomerKey, ProductKey, ChannelCode, RegionCode, CategoryCode, CampaignCode,
               CAST(NULL AS nvarchar(30)) AS ReturnReason, Quantity, UnitListPrice, DiscountPct, GrossSales, DiscountAmount,
               CAST(0 AS decimal(14,2)) AS ReturnAmount, GrossSales - DiscountAmount AS NetRevenue, UnitCost,
               CAST(ROUND(Quantity * UnitCost, 2) AS decimal(14,2)) AS Cogs, IsCostCarriedForward,
               CAST(0 AS bit) AS IsQuantityCapped, CAST(IIF(InvoiceDate < OrderDate, 1, 0) AS bit) AS IsInvoiceBeforeOrder,
               CAST(IIF(CampaignCode IS NULL AND DiscountPct < 100, 1, 0) AS bit) AS IsPolicyChecked,
               CAST(IIF(CampaignCode IS NULL AND DiscountPct < 100 AND DiscountPct > MaxContractPct,
                        ROUND(GrossSales * (DiscountPct - MaxContractPct) / 100, 2), 0) AS decimal(14,2)) AS DiscountAbovePolicy,
               PromotionPeriod
        INTO #Sales
        FROM #Line
        WHERE InvoiceId IS NOT NULL
        UNION ALL
        SELECT r.CreditNoteId, r.CreditLineNumber, 'Return', r.OrderId, r.LineNumber, r.InvoiceId, r.CreditDate, r.InvoiceDate,
               r.OrderDate, r.CustomerKey, r.ProductKey, r.ChannelCode, r.RegionCode, r.CategoryCode, r.CampaignCode,
               r.Reason, -r.ReturnedQuantity, r.UnitListPrice, r.DiscountPct, 0, 0, v.ReturnAmount, -v.ReturnAmount, r.UnitCost,
               IIF(r.IsRestockable = 1, -CAST(ROUND(r.ReturnedQuantity * r.UnitCost, 2) AS decimal(14,2)), 0),
               r.IsCostCarriedForward, CAST(IIF(r.ReturnedQuantity < r.Quantity, 1, 0) AS bit),
               CAST(IIF(r.InvoiceDate < r.OrderDate, 1, 0) AS bit), CAST(0 AS bit), 0, r.PromotionPeriod
        FROM returned AS r
        CROSS APPLY (SELECT CAST(r.ReturnedQuantity * r.UnitListPrice AS decimal(14,2)) AS GrossReturned) AS g
        CROSS APPLY (SELECT CAST(g.GrossReturned - ROUND(g.GrossReturned * r.DiscountPct / 100, 2) AS decimal(14,2)) AS ReturnAmount) AS v;

        /* Facts */

        DECLARE @SalesAction TABLE (Action nvarchar(10) NOT NULL);
        WITH target AS (
            SELECT * FROM dw.FactSales AS f
            WHERE EXISTS (SELECT 1 FROM #AffectedOrder AS a WHERE a.OrderId = f.OrderId)
        )
        MERGE target AS t
        USING #Sales AS s
           ON t.DocumentId = s.DocumentId AND t.DocumentLine = s.DocumentLine
        WHEN MATCHED AND EXISTS (
                SELECT s.LineType, s.OrderId, s.OrderLineNumber, s.InvoiceId, s.PostingDate, s.OriginalInvoiceDate, s.OrderDate,
                       s.CustomerKey, s.ProductKey, s.ChannelCode, s.RegionCode, s.CategoryCode, s.CampaignCode, s.ReturnReason,
                       s.Quantity, s.UnitListPrice, s.DiscountPct, s.GrossSales, s.DiscountAmount, s.ReturnAmount, s.NetRevenue,
                       s.UnitCost, s.Cogs, s.IsCostCarriedForward, s.IsQuantityCapped, s.IsInvoiceBeforeOrder,
                       s.IsPolicyChecked, s.DiscountAbovePolicy, s.PromotionPeriod
                EXCEPT
                SELECT t.LineType, t.OrderId, t.OrderLineNumber, t.InvoiceId, t.PostingDate, t.OriginalInvoiceDate, t.OrderDate,
                       t.CustomerKey, t.ProductKey, t.ChannelCode, t.RegionCode, t.CategoryCode, t.CampaignCode, t.ReturnReason,
                       t.Quantity, t.UnitListPrice, t.DiscountPct, t.GrossSales, t.DiscountAmount, t.ReturnAmount, t.NetRevenue,
                       t.UnitCost, t.Cogs, t.IsCostCarriedForward, t.IsQuantityCapped, t.IsInvoiceBeforeOrder,
                       t.IsPolicyChecked, t.DiscountAbovePolicy, t.PromotionPeriod) THEN
            UPDATE SET LineType = s.LineType, OrderId = s.OrderId, OrderLineNumber = s.OrderLineNumber, InvoiceId = s.InvoiceId,
                       PostingDate = s.PostingDate, OriginalInvoiceDate = s.OriginalInvoiceDate, OrderDate = s.OrderDate,
                       CustomerKey = s.CustomerKey, ProductKey = s.ProductKey, ChannelCode = s.ChannelCode,
                       RegionCode = s.RegionCode, CategoryCode = s.CategoryCode, CampaignCode = s.CampaignCode,
                       ReturnReason = s.ReturnReason, Quantity = s.Quantity, UnitListPrice = s.UnitListPrice,
                       DiscountPct = s.DiscountPct, GrossSales = s.GrossSales, DiscountAmount = s.DiscountAmount,
                       ReturnAmount = s.ReturnAmount, NetRevenue = s.NetRevenue, UnitCost = s.UnitCost, Cogs = s.Cogs,
                       IsCostCarriedForward = s.IsCostCarriedForward, IsQuantityCapped = s.IsQuantityCapped,
                       IsInvoiceBeforeOrder = s.IsInvoiceBeforeOrder, IsPolicyChecked = s.IsPolicyChecked,
                       DiscountAbovePolicy = s.DiscountAbovePolicy, PromotionPeriod = s.PromotionPeriod
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (DocumentId, DocumentLine, LineType, OrderId, OrderLineNumber, InvoiceId, PostingDate, OriginalInvoiceDate,
                    OrderDate, CustomerKey, ProductKey, ChannelCode, RegionCode, CategoryCode, CampaignCode, ReturnReason,
                    Quantity, UnitListPrice, DiscountPct, GrossSales, DiscountAmount, ReturnAmount, NetRevenue, UnitCost, Cogs,
                    IsCostCarriedForward, IsQuantityCapped, IsInvoiceBeforeOrder, IsPolicyChecked, DiscountAbovePolicy,
                    PromotionPeriod)
            VALUES (s.DocumentId, s.DocumentLine, s.LineType, s.OrderId, s.OrderLineNumber, s.InvoiceId, s.PostingDate,
                    s.OriginalInvoiceDate, s.OrderDate, s.CustomerKey, s.ProductKey, s.ChannelCode, s.RegionCode,
                    s.CategoryCode, s.CampaignCode, s.ReturnReason, s.Quantity, s.UnitListPrice, s.DiscountPct, s.GrossSales,
                    s.DiscountAmount, s.ReturnAmount, s.NetRevenue, s.UnitCost, s.Cogs, s.IsCostCarriedForward,
                    s.IsQuantityCapped, s.IsInvoiceBeforeOrder, s.IsPolicyChecked, s.DiscountAbovePolicy, s.PromotionPeriod)
        WHEN NOT MATCHED BY SOURCE THEN
            DELETE
        OUTPUT $action INTO @SalesAction (Action);

        DECLARE @OrderLineAction TABLE (Action nvarchar(10) NOT NULL);
        WITH target AS (
            SELECT * FROM dw.FactOrderLine AS f
            WHERE EXISTS (SELECT 1 FROM #AffectedOrder AS a WHERE a.OrderId = f.OrderId)
        )
        MERGE target AS t
        USING (SELECT OrderId, LineNumber, OrderDate, Status AS OrderStatus, CancelledDate, InvoiceDate, CustomerKey,
                      ProductKey, ChannelCode, RegionCode, CategoryCode, CampaignCode, Quantity,
                      GrossSales - DiscountAmount AS OrderValue
               FROM #Line) AS s
           ON t.OrderId = s.OrderId AND t.LineNumber = s.LineNumber
        WHEN MATCHED AND EXISTS (
                SELECT s.OrderDate, s.OrderStatus, s.CancelledDate, s.InvoiceDate, s.CustomerKey, s.ProductKey, s.ChannelCode,
                       s.RegionCode, s.CategoryCode, s.CampaignCode, s.Quantity, s.OrderValue
                EXCEPT
                SELECT t.OrderDate, t.OrderStatus, t.CancelledDate, t.InvoiceDate, t.CustomerKey, t.ProductKey, t.ChannelCode,
                       t.RegionCode, t.CategoryCode, t.CampaignCode, t.Quantity, t.OrderValue) THEN
            UPDATE SET OrderDate = s.OrderDate, OrderStatus = s.OrderStatus, CancelledDate = s.CancelledDate,
                       InvoiceDate = s.InvoiceDate, CustomerKey = s.CustomerKey, ProductKey = s.ProductKey,
                       ChannelCode = s.ChannelCode, RegionCode = s.RegionCode, CategoryCode = s.CategoryCode,
                       CampaignCode = s.CampaignCode, Quantity = s.Quantity, OrderValue = s.OrderValue
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (OrderId, LineNumber, OrderDate, OrderStatus, CancelledDate, InvoiceDate, CustomerKey, ProductKey,
                    ChannelCode, RegionCode, CategoryCode, CampaignCode, Quantity, OrderValue)
            VALUES (s.OrderId, s.LineNumber, s.OrderDate, s.OrderStatus, s.CancelledDate, s.InvoiceDate, s.CustomerKey,
                    s.ProductKey, s.ChannelCode, s.RegionCode, s.CategoryCode, s.CampaignCode, s.Quantity, s.OrderValue)
        WHEN NOT MATCHED BY SOURCE THEN
            DELETE
        OUTPUT $action INTO @OrderLineAction (Action);

        -- After a full reload the calendar spans exactly the years in the source
        IF @FullReload = 1
            DELETE FROM dw.DimDate WHERE [Date] NOT BETWEEN @FirstDate AND @LastDate;

        UPDATE w
        SET LastModifiedAt = n.NewModifiedAt
        FROM etl.Watermark AS w
        JOIN #NewWatermark AS n ON n.SourceTable = w.SourceTable
        WHERE n.NewModifiedAt IS NOT NULL;

        UPDATE etl.LoadRun
        SET FinishedAt = SYSDATETIME(), Status = 'Succeeded',
            AffectedOrders     = (SELECT COUNT(*) FROM #AffectedOrder),
            SalesInserted      = (SELECT COUNT(*) FROM @SalesAction WHERE Action = 'INSERT'),
            SalesUpdated       = (SELECT COUNT(*) FROM @SalesAction WHERE Action = 'UPDATE'),
            SalesDeleted       = (SELECT COUNT(*) FROM @SalesAction WHERE Action = 'DELETE'),
            OrderLinesInserted = (SELECT COUNT(*) FROM @OrderLineAction WHERE Action = 'INSERT'),
            OrderLinesUpdated  = (SELECT COUNT(*) FROM @OrderLineAction WHERE Action = 'UPDATE'),
            OrderLinesDeleted  = (SELECT COUNT(*) FROM @OrderLineAction WHERE Action = 'DELETE')
        WHERE RunId = @RunId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        UPDATE etl.LoadRun
        SET FinishedAt = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE()
        WHERE RunId = @RunId;
        THROW;
    END CATCH;

    SELECT RunId, Mode, StartedAt, FinishedAt, Status, AffectedOrders, SalesInserted, SalesUpdated, SalesDeleted,
           OrderLinesInserted, OrderLinesUpdated, OrderLinesDeleted
    FROM etl.LoadRun
    WHERE RunId = @RunId;
END;
GO
