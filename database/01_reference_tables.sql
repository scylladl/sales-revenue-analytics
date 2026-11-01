/*
    Step 01: reference data. Tables are created when missing and their rows are upserted, so the script can run
    again after a change (for example a new discount policy).
*/
USE VelmoraSales;
GO

IF OBJECT_ID(N'ref.Channel') IS NULL
CREATE TABLE ref.Channel (
    ChannelCode  varchar(6)   NOT NULL CONSTRAINT PK_Channel PRIMARY KEY,
    ChannelName  nvarchar(30) NOT NULL,
    SortOrder    tinyint      NOT NULL
);

IF OBJECT_ID(N'ref.Region') IS NULL
CREATE TABLE ref.Region (
    RegionCode  char(3)      NOT NULL CONSTRAINT PK_Region PRIMARY KEY,
    RegionName  nvarchar(40) NOT NULL,
    SortOrder   tinyint      NOT NULL
);

-- IsRestockable: returned goods go back to stock and their cost is reversed (rule R5); food is written off
IF OBJECT_ID(N'ref.Category') IS NULL
CREATE TABLE ref.Category (
    CategoryCode   varchar(6)   NOT NULL CONSTRAINT PK_Category PRIMARY KEY,
    CategoryName   nvarchar(30) NOT NULL,
    IsCoffee       bit          NOT NULL,
    IsRestockable  bit          NOT NULL,
    SortOrder      tinyint      NOT NULL
);

-- Contract discount the company allows by channel and customer segment (promotions come on top)
IF OBJECT_ID(N'ref.DiscountPolicy') IS NULL
CREATE TABLE ref.DiscountPolicy (
    ChannelCode      varchar(6)   NOT NULL,
    Segment          varchar(10)  NOT NULL,
    MaxContractPct   decimal(5,2) NOT NULL,
    CONSTRAINT PK_DiscountPolicy PRIMARY KEY (ChannelCode, Segment),
    CONSTRAINT FK_DiscountPolicy_Channel FOREIGN KEY (ChannelCode) REFERENCES ref.Channel (ChannelCode)
);
GO

MERGE ref.Channel AS t
USING (VALUES ('HORECA', N'HoReCa', 1), ('RETAIL', N'Retail', 2), ('ECOM', N'E-commerce', 3))
      AS s (ChannelCode, ChannelName, SortOrder)
   ON t.ChannelCode = s.ChannelCode
WHEN MATCHED THEN UPDATE SET ChannelName = s.ChannelName, SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT VALUES (s.ChannelCode, s.ChannelName, s.SortOrder);

MERGE ref.Region AS t
USING (VALUES ('VAL', N'Valencia & Murcia', 1), ('CAT', N'Catalonia & Balearics', 2), ('MAD', N'Madrid & Centre', 3),
              ('AND', N'Andalusia', 4), ('NOR', N'North', 5), ('NWE', N'Northwest', 6),
              ('UNK', N'Unknown', 9))   -- customers exported without a region
      AS s (RegionCode, RegionName, SortOrder)
   ON t.RegionCode = s.RegionCode
WHEN MATCHED THEN UPDATE SET RegionName = s.RegionName, SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT VALUES (s.RegionCode, s.RegionName, s.SortOrder);

MERGE ref.Category AS t
USING (VALUES ('BEANS', N'Whole Beans', 1, 0, 1), ('GROUND', N'Ground Coffee', 1, 0, 2), ('CAPS', N'Capsules', 1, 0, 3),
              ('GIFT', N'Gift Packs', 1, 0, 4), ('ACCS', N'Accessories', 0, 1, 5), ('EQUIP', N'Equipment', 0, 1, 6))
      AS s (CategoryCode, CategoryName, IsCoffee, IsRestockable, SortOrder)
   ON t.CategoryCode = s.CategoryCode
WHEN MATCHED THEN UPDATE SET CategoryName = s.CategoryName, IsCoffee = s.IsCoffee, IsRestockable = s.IsRestockable,
                             SortOrder = s.SortOrder
WHEN NOT MATCHED THEN INSERT VALUES (s.CategoryCode, s.CategoryName, s.IsCoffee, s.IsRestockable, s.SortOrder);

MERGE ref.DiscountPolicy AS t
USING (VALUES ('HORECA', 'Gold', 12.0), ('HORECA', 'Silver', 8.0), ('HORECA', 'Bronze', 4.0),
              ('RETAIL', 'Chain', 5.0), ('RETAIL', 'Gourmet', 2.0), ('ECOM', 'Consumer', 0.0))
      AS s (ChannelCode, Segment, MaxContractPct)
   ON t.ChannelCode = s.ChannelCode AND t.Segment = s.Segment
WHEN MATCHED THEN UPDATE SET MaxContractPct = s.MaxContractPct
WHEN NOT MATCHED THEN INSERT VALUES (s.ChannelCode, s.Segment, s.MaxContractPct);
GO
