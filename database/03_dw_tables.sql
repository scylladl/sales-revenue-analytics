/*
    Step 03: star schema (dw) and load control (etl). Loaded only by etl.usp_LoadSales (step 04).

    Facts carry the channel, region and category codes directly, so the budget (planned at that grain) and the
    actuals filter through the same small dimensions without bidirectional relationships.
    Amounts exclude VAT and are rounded to cents on each line, as the ERP does.
*/
USE VelmoraSales;
GO

IF OBJECT_ID(N'dw.DimDate') IS NULL
CREATE TABLE dw.DimDate (
    [Date]        date         NOT NULL CONSTRAINT PK_DimDate PRIMARY KEY,
    [Year]        smallint     NOT NULL,
    [Quarter]     tinyint      NOT NULL,
    MonthNumber   tinyint      NOT NULL,
    MonthName     varchar(9)   NOT NULL,
    YearMonth     int          NOT NULL,   -- 202501
    MonthStart    date         NOT NULL,
    DayOfMonth    tinyint      NOT NULL,
    IsoWeekday    tinyint      NOT NULL    -- 1 = Monday
);

IF OBJECT_ID(N'dw.DimCustomer') IS NULL
CREATE TABLE dw.DimCustomer (
    CustomerKey   int           IDENTITY CONSTRAINT PK_DimCustomer PRIMARY KEY,
    CustomerId    varchar(7)    NOT NULL CONSTRAINT UQ_DimCustomer UNIQUE,
    CustomerName  nvarchar(80)  NOT NULL,
    ChannelCode   varchar(6)    NOT NULL CONSTRAINT FK_DimCustomer_Channel REFERENCES ref.Channel (ChannelCode),
    Segment       varchar(10)   NOT NULL,
    RegionCode    char(3)       NOT NULL CONSTRAINT FK_DimCustomer_Region REFERENCES ref.Region (RegionCode),   -- UNK when the export has no region
    City          nvarchar(40)  NULL,
    CreatedDate   date          NULL
);

IF OBJECT_ID(N'dw.DimProduct') IS NULL
CREATE TABLE dw.DimProduct (
    ProductKey    int           IDENTITY CONSTRAINT PK_DimProduct PRIMARY KEY,
    ProductId     varchar(12)   NOT NULL CONSTRAINT UQ_DimProduct UNIQUE,
    ProductName   nvarchar(80)  NOT NULL,
    CategoryCode  varchar(6)    NOT NULL CONSTRAINT FK_DimProduct_Category REFERENCES ref.Category (CategoryCode),
    PackSize      varchar(10)   NOT NULL,
    LaunchDate    date          NOT NULL
);

/*
    One row per invoice line and per credit note line (rules R1, R2, R4, R5).
    Invoice line: Quantity, GrossSales, DiscountAmount, NetRevenue and Cogs are positive, ReturnAmount is 0.
    Return line:  Quantity is negative, ReturnAmount is the net value returned, NetRevenue = -ReturnAmount,
                  Cogs reverses the original cost only for restockable categories (coffee is written off).
    PostingDate is the invoice date or the credit note date; OriginalInvoiceDate attributes a return to its sale.
*/
IF OBJECT_ID(N'dw.FactSales') IS NULL
CREATE TABLE dw.FactSales (
    DocumentId            varchar(9)     NOT NULL,   -- invoice (FV...) or credit note (AB...)
    DocumentLine          smallint       NOT NULL,
    LineType              varchar(7)     NOT NULL CONSTRAINT CK_FactSales_LineType CHECK (LineType IN ('Invoice', 'Return')),
    OrderId               varchar(9)     NOT NULL,
    OrderLineNumber       smallint       NOT NULL,
    InvoiceId             varchar(9)     NOT NULL,
    PostingDate           date           NOT NULL CONSTRAINT FK_FactSales_PostingDate REFERENCES dw.DimDate ([Date]),
    OriginalInvoiceDate   date           NOT NULL,
    OrderDate             date           NOT NULL,
    CustomerKey           int            NOT NULL CONSTRAINT FK_FactSales_Customer REFERENCES dw.DimCustomer (CustomerKey),
    ProductKey            int            NOT NULL CONSTRAINT FK_FactSales_Product REFERENCES dw.DimProduct (ProductKey),
    ChannelCode           varchar(6)     NOT NULL CONSTRAINT FK_FactSales_Channel REFERENCES ref.Channel (ChannelCode),
    RegionCode            char(3)        NOT NULL CONSTRAINT FK_FactSales_Region REFERENCES ref.Region (RegionCode),
    CategoryCode          varchar(6)     NOT NULL CONSTRAINT FK_FactSales_Category REFERENCES ref.Category (CategoryCode),
    CampaignCode          varchar(12)    NULL,
    ReturnReason          nvarchar(30)   NULL,
    Quantity              int            NOT NULL,
    UnitListPrice         decimal(10,2)  NOT NULL,
    DiscountPct           decimal(5,1)   NOT NULL,
    GrossSales            decimal(14,2)  NOT NULL,
    DiscountAmount        decimal(14,2)  NOT NULL,
    ReturnAmount          decimal(14,2)  NOT NULL,
    NetRevenue            decimal(14,2)  NOT NULL,
    UnitCost              decimal(10,4)  NOT NULL,
    Cogs                  decimal(14,2)  NOT NULL,
    IsCostCarriedForward  bit            NOT NULL,   -- no standard cost for the month; latest earlier cost used
    IsQuantityCapped      bit            NOT NULL,   -- return quantity above what was invoiced; capped
    IsInvoiceBeforeOrder  bit            NOT NULL,   -- invoice dated before its order; date kept
    CONSTRAINT PK_FactSales PRIMARY KEY (DocumentId, DocumentLine)
);

-- One row per order line, whatever its status: orders taken, cancellations and the open backlog (rule R3)
IF OBJECT_ID(N'dw.FactOrderLine') IS NULL
CREATE TABLE dw.FactOrderLine (
    OrderId          varchar(9)     NOT NULL,
    LineNumber       smallint       NOT NULL,
    OrderDate        date           NOT NULL CONSTRAINT FK_FactOrderLine_OrderDate REFERENCES dw.DimDate ([Date]),
    OrderStatus      varchar(9)     NOT NULL,
    CancelledDate    date           NULL,
    InvoiceDate      date           NULL,
    CustomerKey      int            NOT NULL CONSTRAINT FK_FactOrderLine_Customer REFERENCES dw.DimCustomer (CustomerKey),
    ProductKey       int            NOT NULL CONSTRAINT FK_FactOrderLine_Product REFERENCES dw.DimProduct (ProductKey),
    ChannelCode      varchar(6)     NOT NULL CONSTRAINT FK_FactOrderLine_Channel REFERENCES ref.Channel (ChannelCode),
    RegionCode       char(3)        NOT NULL CONSTRAINT FK_FactOrderLine_Region REFERENCES ref.Region (RegionCode),
    CategoryCode     varchar(6)     NOT NULL CONSTRAINT FK_FactOrderLine_Category REFERENCES ref.Category (CategoryCode),
    CampaignCode     varchar(12)    NULL,
    Quantity         int            NOT NULL,
    OrderValue       decimal(14,2)  NOT NULL,   -- net of the line discount, excluding VAT
    CONSTRAINT PK_FactOrderLine PRIMARY KEY (OrderId, LineNumber)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_FactSales_OrderId')
    CREATE INDEX IX_FactSales_OrderId ON dw.FactSales (OrderId);
GO

-- Last ModifiedAt processed per source table
IF OBJECT_ID(N'etl.Watermark') IS NULL
CREATE TABLE etl.Watermark (
    SourceTable     sysname       NOT NULL CONSTRAINT PK_Watermark PRIMARY KEY,
    LastModifiedAt  datetime2(0)  NOT NULL
);

IF OBJECT_ID(N'etl.LoadRun') IS NULL
CREATE TABLE etl.LoadRun (
    RunId               int             IDENTITY CONSTRAINT PK_LoadRun PRIMARY KEY,
    Mode                varchar(11)     NOT NULL,   -- Full or Incremental
    StartedAt           datetime2(0)    NOT NULL,
    FinishedAt          datetime2(0)    NULL,
    Status              varchar(9)      NOT NULL,   -- Running, Succeeded, Failed
    AffectedOrders      int             NULL,
    SalesInserted       int             NULL,
    SalesUpdated        int             NULL,
    SalesDeleted        int             NULL,
    OrderLinesInserted  int             NULL,
    OrderLinesUpdated   int             NULL,
    OrderLinesDeleted   int             NULL,
    ErrorMessage        nvarchar(4000)  NULL
);
GO

MERGE etl.Watermark AS t
USING (VALUES (N'src.Customer'), (N'src.Product'), (N'src.StandardCost'), (N'src.SalesOrder'), (N'src.SalesOrderLine'),
              (N'src.Invoice'), (N'src.CreditNote'), (N'src.CreditNoteLine')) AS s (SourceTable)
   ON t.SourceTable = s.SourceTable
WHEN NOT MATCHED THEN INSERT (SourceTable, LastModifiedAt) VALUES (s.SourceTable, '1900-01-01');
GO
