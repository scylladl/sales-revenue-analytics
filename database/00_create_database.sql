/*
    Velmora Coffee Roasters (fictional) - Sales & Revenue Analytics
    Step 00: database and schemas. Safe to run more than once.

    ref  reference data maintained by the company: channels, regions, categories, discount policy
    src  ERP exports (orders, invoices, credit notes, customers, products, prices, standard costs)
    etl  processing control: watermarks and run log
    dw   star schema loaded incrementally by etl.usp_LoadSales
    dq   data quality checks
    rpt  views read by Power BI
*/
IF DB_ID(N'VelmoraSales') IS NULL
    CREATE DATABASE VelmoraSales;
GO

USE VelmoraSales;
GO

IF SCHEMA_ID(N'ref') IS NULL EXEC (N'CREATE SCHEMA ref');
IF SCHEMA_ID(N'src') IS NULL EXEC (N'CREATE SCHEMA src');
IF SCHEMA_ID(N'etl') IS NULL EXEC (N'CREATE SCHEMA etl');
IF SCHEMA_ID(N'dw')  IS NULL EXEC (N'CREATE SCHEMA dw');
IF SCHEMA_ID(N'dq')  IS NULL EXEC (N'CREATE SCHEMA dq');
IF SCHEMA_ID(N'rpt') IS NULL EXEC (N'CREATE SCHEMA rpt');
GO
