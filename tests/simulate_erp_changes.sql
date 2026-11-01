/*
    One day of simulated ERP activity after the data cut, used by tests/test_incremental_load.ps1.
    Every change carries ModifiedAt = 2026-01-02 08:00, later than every watermark.
*/
SET XACT_ABORT ON;
BEGIN TRANSACTION;

DECLARE @At datetime2(0) = '2026-01-02T08:00:00';

-- 1. The 20 oldest open orders are invoiced on 2 January
DECLARE @Invoiced TABLE (OrderId varchar(9) PRIMARY KEY, Seq int NOT NULL);
INSERT @Invoiced (OrderId, Seq)
SELECT TOP (20) OrderId, ROW_NUMBER() OVER (ORDER BY OrderId)
FROM src.SalesOrder
WHERE Status = 'Open'
ORDER BY OrderId;

UPDATE o SET Status = 'Invoiced', ModifiedAt = @At
FROM src.SalesOrder AS o
JOIN @Invoiced AS i ON i.OrderId = o.OrderId;

INSERT src.Invoice (InvoiceId, OrderId, InvoiceDate, ModifiedAt)
SELECT CONCAT('FVT', FORMAT(Seq, '000000')), OrderId, '2026-01-02', @At
FROM @Invoiced;

-- 2. The next 10 open orders are cancelled
WITH nextOpen AS (
    SELECT TOP (10) Status, CancelledAt, ModifiedAt
    FROM src.SalesOrder
    WHERE Status = 'Open'
    ORDER BY OrderId
)
UPDATE nextOpen SET Status = 'Cancelled', CancelledAt = @At, ModifiedAt = @At;

-- 3. A customer returns one unit of an e-commerce equipment line invoiced in December 2025
DECLARE @OrderId varchar(9), @LineNumber smallint, @InvoiceId varchar(9);
SELECT TOP (1) @OrderId = l.OrderId, @LineNumber = l.LineNumber, @InvoiceId = i.InvoiceId
FROM src.SalesOrderLine AS l
JOIN src.SalesOrder AS o ON o.OrderId = l.OrderId
JOIN src.Invoice AS i ON i.OrderId = o.OrderId
JOIN src.Product AS p ON p.ProductId = l.ProductId
WHERE o.ChannelCode = 'ECOM' AND p.CategoryCode = 'EQUIP' AND i.InvoiceDate >= '2025-12-01'
  AND NOT EXISTS (SELECT 1 FROM src.CreditNoteLine AS cl WHERE cl.OrderId = l.OrderId AND cl.LineNumber = l.LineNumber)
ORDER BY l.OrderId, l.LineNumber;

INSERT src.CreditNote (CreditNoteId, InvoiceId, CreditDate, Reason, ModifiedAt)
VALUES ('ABT000001', @InvoiceId, '2026-01-02', N'Changed mind', @At);
INSERT src.CreditNoteLine (CreditNoteId, CreditLineNumber, OrderId, LineNumber, Quantity, ModifiedAt)
VALUES ('ABT000001', 1, @OrderId, @LineNumber, 1, @At);

-- 4. A second credit note on a line that was already returned in full (must be capped to zero units)
SELECT TOP (1) @OrderId = cl.OrderId, @LineNumber = cl.LineNumber, @InvoiceId = cn.InvoiceId
FROM src.CreditNoteLine AS cl
JOIN src.CreditNote AS cn ON cn.CreditNoteId = cl.CreditNoteId
JOIN src.SalesOrderLine AS l ON l.OrderId = cl.OrderId AND l.LineNumber = cl.LineNumber
WHERE cl.Quantity = l.Quantity
ORDER BY cl.CreditNoteId;

INSERT src.CreditNote (CreditNoteId, InvoiceId, CreditDate, Reason, ModifiedAt)
VALUES ('ABT000002', @InvoiceId, '2026-01-02', N'Duplicate claim', @At);
INSERT src.CreditNoteLine (CreditNoteId, CreditLineNumber, OrderId, LineNumber, Quantity, ModifiedAt)
VALUES ('ABT000002', 1, @OrderId, @LineNumber, 1, @At);

-- 5. A HoReCa customer in Andalusia moves to Madrid (its history follows the customer's current region)
UPDATE src.Customer
SET RegionCode = 'MAD', City = N'Madrid', ModifiedAt = @At
WHERE CustomerId = (SELECT TOP (1) c.CustomerId
                    FROM src.Customer AS c
                    WHERE c.ChannelCode = 'HORECA' AND c.RegionCode = 'AND'
                      AND EXISTS (SELECT 1 FROM src.SalesOrder AS o WHERE o.CustomerId = c.CustomerId AND o.Status = 'Invoiced')
                    ORDER BY c.CustomerId);

-- 6. Finance adds the missing September 2024 standard cost of VEL-BN-03K
INSERT src.StandardCost (ProductId, YearMonth, UnitCost, ModifiedAt)
SELECT ProductId, 202409, ROUND(UnitCost * 1.01, 4), @At
FROM src.StandardCost
WHERE ProductId = 'VEL-BN-03K' AND YearMonth = 202408;

-- 7. A product name is corrected (dimension change only)
UPDATE src.Product
SET ProductName = CONCAT(ProductName, N' (new pack)'), ModifiedAt = @At
WHERE ProductId = (SELECT TOP (1) ProductId FROM src.Product WHERE CategoryCode = 'ACCS' ORDER BY ProductId);

-- 8. An open order line changes quantity
WITH openLine AS (
    SELECT TOP (1) l.Quantity, l.ModifiedAt
    FROM src.SalesOrderLine AS l
    JOIN src.SalesOrder AS o ON o.OrderId = l.OrderId
    WHERE o.Status = 'Open'
    ORDER BY l.OrderId, l.LineNumber
)
UPDATE openLine SET Quantity = Quantity + 2, ModifiedAt = @At;

COMMIT TRANSACTION;
