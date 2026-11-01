/*
    Step 02: ERP export tables (schema src), loaded by database/load_source_data.ps1.

    They keep the ERP's own keys and a ModifiedAt timestamp per row: the scheduled load (step 04) reads only the
    rows changed since its last run. Constraints are only those the ERP guarantees; known defects in the exports
    (docs/03-data-model.md, "Source defects") are allowed here and handled by the load.
*/
USE VelmoraSales;
GO

IF OBJECT_ID(N'src.Product') IS NULL
CREATE TABLE src.Product (
    ProductId     varchar(12)   NOT NULL CONSTRAINT PK_SrcProduct PRIMARY KEY,
    ProductName   nvarchar(80)  NOT NULL,
    CategoryCode  varchar(6)    NOT NULL CONSTRAINT FK_SrcProduct_Category REFERENCES ref.Category (CategoryCode),
    PackSize      varchar(10)   NOT NULL,
    LaunchDate    date          NOT NULL,
    VatRate       decimal(4,1)  NOT NULL,
    IsFood        bit           NOT NULL,
    ModifiedAt    datetime2(0)  NOT NULL
);

IF OBJECT_ID(N'src.Customer') IS NULL
CREATE TABLE src.Customer (
    CustomerId    varchar(7)    NOT NULL CONSTRAINT PK_SrcCustomer PRIMARY KEY,
    CustomerName  nvarchar(80)  NOT NULL,
    ChannelCode   varchar(6)    NOT NULL CONSTRAINT FK_SrcCustomer_Channel REFERENCES ref.Channel (ChannelCode),
    Segment       varchar(10)   NOT NULL,
    RegionCode    char(3)       NULL,      -- missing for some customers in the export
    City          nvarchar(40)  NULL,
    CreatedDate   date          NULL,
    ModifiedAt    datetime2(0)  NOT NULL
);

IF OBJECT_ID(N'src.PriceList') IS NULL
CREATE TABLE src.PriceList (
    ProductId    varchar(12)   NOT NULL CONSTRAINT FK_SrcPriceList_Product REFERENCES src.Product (ProductId),
    ChannelCode  varchar(6)    NOT NULL CONSTRAINT FK_SrcPriceList_Channel REFERENCES ref.Channel (ChannelCode),
    ValidFrom    date          NOT NULL,
    ValidTo      date          NULL,
    ListPrice    decimal(10,2) NOT NULL,
    CONSTRAINT PK_SrcPriceList PRIMARY KEY (ProductId, ChannelCode, ValidFrom)
);

-- Monthly standard cost per unit, revised by finance as green coffee prices move (rule R5)
IF OBJECT_ID(N'src.StandardCost') IS NULL
CREATE TABLE src.StandardCost (
    ProductId   varchar(12)   NOT NULL CONSTRAINT FK_SrcStandardCost_Product REFERENCES src.Product (ProductId),
    YearMonth   int           NOT NULL,
    UnitCost    decimal(10,4) NOT NULL,
    ModifiedAt  datetime2(0)  NOT NULL,
    CONSTRAINT PK_SrcStandardCost PRIMARY KEY (ProductId, YearMonth)
);

IF OBJECT_ID(N'src.SalesOrder') IS NULL
CREATE TABLE src.SalesOrder (
    OrderId       varchar(9)    NOT NULL CONSTRAINT PK_SrcSalesOrder PRIMARY KEY,
    CustomerId    varchar(7)    NOT NULL CONSTRAINT FK_SrcSalesOrder_Customer REFERENCES src.Customer (CustomerId),
    ChannelCode   varchar(6)    NOT NULL CONSTRAINT FK_SrcSalesOrder_Channel REFERENCES ref.Channel (ChannelCode),
    OrderDate     date          NOT NULL,
    CampaignCode  varchar(12)   NULL,
    Status        varchar(9)    NOT NULL CONSTRAINT CK_SrcSalesOrder_Status CHECK (Status IN ('Open', 'Invoiced', 'Cancelled')),
    CreatedAt     datetime2(0)  NOT NULL,
    CancelledAt   datetime2(0)  NULL,
    ModifiedAt    datetime2(0)  NOT NULL
);

IF OBJECT_ID(N'src.SalesOrderLine') IS NULL
CREATE TABLE src.SalesOrderLine (
    OrderId        varchar(9)    NOT NULL CONSTRAINT FK_SrcSalesOrderLine_Order REFERENCES src.SalesOrder (OrderId),
    LineNumber     smallint      NOT NULL,
    ProductId      varchar(12)   NOT NULL CONSTRAINT FK_SrcSalesOrderLine_Product REFERENCES src.Product (ProductId),
    Quantity       int           NOT NULL,
    UnitListPrice  decimal(10,2) NOT NULL,   -- list price of the order date, excluding VAT
    DiscountPct    decimal(5,1)  NOT NULL,   -- contract plus promotion, applied once on the line
    VatRate        decimal(4,1)  NOT NULL,
    ModifiedAt     datetime2(0)  NOT NULL,
    CONSTRAINT PK_SrcSalesOrderLine PRIMARY KEY (OrderId, LineNumber)
);

-- One invoice per order (the company does not ship partial orders)
IF OBJECT_ID(N'src.Invoice') IS NULL
CREATE TABLE src.Invoice (
    InvoiceId    varchar(9)    NOT NULL CONSTRAINT PK_SrcInvoice PRIMARY KEY,
    OrderId      varchar(9)    NOT NULL CONSTRAINT FK_SrcInvoice_Order REFERENCES src.SalesOrder (OrderId)
                               CONSTRAINT UQ_SrcInvoice_Order UNIQUE,
    InvoiceDate  date          NOT NULL,
    ModifiedAt   datetime2(0)  NOT NULL
);

IF OBJECT_ID(N'src.CreditNote') IS NULL
CREATE TABLE src.CreditNote (
    CreditNoteId  varchar(9)    NOT NULL CONSTRAINT PK_SrcCreditNote PRIMARY KEY,
    InvoiceId     varchar(9)    NOT NULL CONSTRAINT FK_SrcCreditNote_Invoice REFERENCES src.Invoice (InvoiceId),
    CreditDate    date          NOT NULL,
    Reason        nvarchar(30)  NOT NULL,
    ModifiedAt    datetime2(0)  NOT NULL
);

IF OBJECT_ID(N'src.CreditNoteLine') IS NULL
CREATE TABLE src.CreditNoteLine (
    CreditNoteId      varchar(9)    NOT NULL CONSTRAINT FK_SrcCreditNoteLine_CreditNote REFERENCES src.CreditNote (CreditNoteId),
    CreditLineNumber  smallint      NOT NULL,
    OrderId           varchar(9)    NOT NULL,
    LineNumber        smallint      NOT NULL,
    Quantity          int           NOT NULL,
    ModifiedAt        datetime2(0)  NOT NULL,
    CONSTRAINT PK_SrcCreditNoteLine PRIMARY KEY (CreditNoteId, CreditLineNumber),
    CONSTRAINT FK_SrcCreditNoteLine_OrderLine FOREIGN KEY (OrderId, LineNumber) REFERENCES src.SalesOrderLine (OrderId, LineNumber)
);
GO

-- The scheduled load filters every table on ModifiedAt
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_SrcSalesOrder_ModifiedAt')
    CREATE INDEX IX_SrcSalesOrder_ModifiedAt ON src.SalesOrder (ModifiedAt);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_SrcSalesOrderLine_ModifiedAt')
    CREATE INDEX IX_SrcSalesOrderLine_ModifiedAt ON src.SalesOrderLine (ModifiedAt) INCLUDE (OrderId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_SrcInvoice_ModifiedAt')
    CREATE INDEX IX_SrcInvoice_ModifiedAt ON src.Invoice (ModifiedAt) INCLUDE (OrderId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_SrcCreditNote_ModifiedAt')
    CREATE INDEX IX_SrcCreditNote_ModifiedAt ON src.CreditNote (ModifiedAt) INCLUDE (InvoiceId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_SrcCreditNoteLine_ModifiedAt')
    CREATE INDEX IX_SrcCreditNoteLine_ModifiedAt ON src.CreditNoteLine (ModifiedAt) INCLUDE (OrderId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_SrcCreditNoteLine_OrderLine')
    CREATE INDEX IX_SrcCreditNoteLine_OrderLine ON src.CreditNoteLine (OrderId, LineNumber) INCLUDE (Quantity, CreditNoteId);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_SrcStandardCost_ModifiedAt')
    CREATE INDEX IX_SrcStandardCost_ModifiedAt ON src.StandardCost (ModifiedAt);
GO
