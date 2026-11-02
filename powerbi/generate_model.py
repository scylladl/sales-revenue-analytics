"""
Writes the VelmoraSales semantic model (powerbi/VelmoraSales.SemanticModel) as TMDL.

The model is authored here rather than by hand so it can be rebuilt and reviewed as code. Lineage tags are uuid5
of the object path, so running the script again gives identical files. Validate the result with
powerbi/validate_model.ps1.

Usage: python powerbi/generate_model.py [--budget-file <path to the budget workbook>]
"""
import argparse
import textwrap
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MODEL = REPO / "powerbi" / "VelmoraSales.SemanticModel"
NS = uuid.UUID("2b7e4f1a-9c3d-4e8b-a1f2-5d6c7b8a9e01")
T = "\t"


def tag(path):
    return str(uuid.uuid5(NS, path))


def q(name):
    """TMDL name quoting."""
    return name if name.replace("_", "").isalnum() and not name[0].isdigit() else "'" + name.replace("'", "''") + "'"


def indent(text, depth):
    lines = textwrap.dedent(text).strip("\n").splitlines()
    return "\n".join(T * depth + line if line.strip() else "" for line in lines)


def col(name, src, dtype, hidden=False, fmt=None, sort=None, key=False, desc=None):
    return dict(name=name, src=src, dtype=dtype, hidden=hidden, fmt=fmt, sort=sort, key=key, desc=desc)


S, I, D, DT, B, M = "string", "int64", "dateTime", "dateTime", "boolean", "decimal"
DATE, MONEY = "dd mmm yyyy", "#,##0.00"

# Tables read from the rpt views: (view, query group, description, columns, Power Query types)
TABLES = {
    "Date": ("vw_Date", "Dimensions", "Calendar of the data period, one row per day (marked as date table).", [
        col("Date", "Date", D, fmt=DATE, key=True),
        col("Year", "Year", I, fmt="0"),
        col("Quarter", "QuarterLabel", S),
        col("Month Number", "MonthNumber", I, hidden=True),
        col("Month Name", "MonthName", S, sort="Month Number"),
        col("Month Short", "MonthShort", S, sort="Month Number"),
        col("Year Month", "YearMonth", I, hidden=True),
        col("Month", "MonthLabel", S, sort="Year Month", desc="Month as 'Mar 2025'."),
        col("Month Start", "MonthStart", D, fmt=DATE),
    ], {"Year": "Int64.Type", "MonthNumber": "Int64.Type", "YearMonth": "Int64.Type"}),
    "Channel": ("vw_Channel", "Dimensions", "Sales channel: HoReCa, Retail, E-commerce.", [
        col("Channel Code", "ChannelCode", S, hidden=True),
        col("Channel", "ChannelName", S, sort="Channel Sort"),
        col("Channel Sort", "SortOrder", I, hidden=True),
    ], {"SortOrder": "Int64.Type"}),
    "Region": ("vw_Region", "Dimensions", "Sales region of the customer. Unknown (UNK) holds customers exported without a region.", [
        col("Region Code", "RegionCode", S),
        col("Region", "RegionName", S, sort="Region Sort"),
        col("Region Sort", "SortOrder", I, hidden=True),
    ], {"SortOrder": "Int64.Type"}),
    "Category": ("vw_Category", "Dimensions", "Product category, the grain of the budget.", [
        col("Category Code", "CategoryCode", S, hidden=True),
        col("Category", "CategoryName", S, sort="Category Sort"),
        col("Is Coffee", "IsCoffee", B),
        col("Category Sort", "SortOrder", I, hidden=True),
    ], {"SortOrder": "Int64.Type"}),
    "Customer": ("vw_Customer", "Dimensions", "Customers: HoReCa accounts, retail stores (one customer per store) and consumers.", [
        col("Customer Key", "CustomerKey", I, hidden=True),
        col("Customer Id", "CustomerId", S),
        col("Customer", "CustomerName", S),
        col("Segment", "Segment", S, desc="HoReCa tier (Gold, Silver, Bronze), retail Chain or Gourmet, e-commerce Consumer."),
        col("City", "City", S),
        col("Created Date", "CreatedDate", D, fmt=DATE),
        col("Is Possible Duplicate", "IsPossibleDuplicate", B,
            desc="Same channel, name and city as another customer id (check SRC-01); kept separate until the sales team decides."),
    ], {"CustomerKey": "Int64.Type"}),
    "Product": ("vw_Product", "Dimensions", "Products (SKUs).", [
        col("Product Key", "ProductKey", I, hidden=True),
        col("Product Id", "ProductId", S),
        col("Product", "ProductName", S),
        col("Pack Size", "PackSize", S),
        col("Launch Date", "LaunchDate", D, fmt=DATE),
    ], {"ProductKey": "Int64.Type"}),
    "Sales": ("vw_Sales", "Facts",
              "One row per invoice line and per credit note line (rules R1 to R5). Amounts exclude VAT. Return rows "
              "carry a negative quantity and net revenue; Posting Date is the invoice or credit note date.", [
        col("Order Id", "OrderId", S, hidden=True),
        col("Line Type", "LineType", S, desc="Invoice or Return."),
        col("Posting Date", "PostingDate", D, hidden=True, fmt=DATE),
        col("Original Invoice Date", "OriginalInvoiceDate", D, hidden=True, fmt=DATE,
            desc="Invoice date of the sale; on return rows it attributes the return to the original sale (inactive relationship)."),
        col("Customer Key", "CustomerKey", I, hidden=True),
        col("Product Key", "ProductKey", I, hidden=True),
        col("Channel Code", "ChannelCode", S, hidden=True),
        col("Region Code", "RegionCode", S, hidden=True),
        col("Category Code", "CategoryCode", S, hidden=True),
        col("Campaign", "CampaignCode", S, desc="E-commerce campaign (Black Friday, Christmas, summer) active on the order."),
        col("Return Reason", "ReturnReason", S),
        col("Quantity", "Quantity", I, hidden=True),
        col("Discount %", "DiscountPct", M, hidden=True, fmt="0.0"),
        col("Gross Sales", "GrossSales", M, hidden=True, fmt=MONEY),
        col("Discount Amount", "DiscountAmount", M, hidden=True, fmt=MONEY),
        col("Return Amount", "ReturnAmount", M, hidden=True, fmt=MONEY),
        col("Net Revenue", "NetRevenue", M, hidden=True, fmt=MONEY),
        col("COGS", "Cogs", M, hidden=True, fmt=MONEY),
        col("Is Cost Carried Forward", "IsCostCarriedForward", B,
            desc="No standard cost for the invoice month; the latest earlier cost was used (check SRC-02)."),
        col("Is Quantity Capped", "IsQuantityCapped", B, desc="Return above the invoiced quantity, capped (check SRC-03)."),
        col("Is Invoice Before Order", "IsInvoiceBeforeOrder", B, desc="Invoice dated before its order; date kept (check SRC-04)."),
    ], {"CustomerKey": "Int64.Type", "ProductKey": "Int64.Type", "Quantity": "Int64.Type", "DiscountPct": "type number",
        "GrossSales": "Currency.Type", "DiscountAmount": "Currency.Type", "ReturnAmount": "Currency.Type",
        "NetRevenue": "Currency.Type", "Cogs": "Currency.Type"}),
    "Order Line": ("vw_OrderLine", "Facts",
                   "One row per order line whatever its status, by order date: orders taken, cancellations and open orders (rule R3).", [
        col("Order Id", "OrderId", S, hidden=True),
        col("Order Date", "OrderDate", D, hidden=True, fmt=DATE),
        col("Order Status", "OrderStatus", S, desc="Invoiced, Cancelled, or Open (not invoiced at the data cut)."),
        col("Customer Key", "CustomerKey", I, hidden=True),
        col("Product Key", "ProductKey", I, hidden=True),
        col("Channel Code", "ChannelCode", S, hidden=True),
        col("Region Code", "RegionCode", S, hidden=True),
        col("Category Code", "CategoryCode", S, hidden=True),
        col("Campaign", "CampaignCode", S, hidden=True),
        col("Quantity", "Quantity", I, hidden=True),
        col("Order Value", "OrderValue", M, hidden=True, fmt=MONEY),
    ], {"CustomerKey": "Int64.Type", "ProductKey": "Int64.Type", "Quantity": "Int64.Type", "OrderValue": "Currency.Type"}),
    "Data Quality Check": ("vw_DataQualityCheck", "Support", "Result of dq.usp_RunChecks after the last load.", [
        col("Check Code", "CheckCode", S),
        col("Check Type", "CheckType", S),
        col("Check", "CheckName", S),
        col("Affected Rows", "AffectedRows", I, fmt="#,##0"),
        col("Unhandled Rows", "UnhandledRows", I, fmt="#,##0"),
        col("Handling", "Handling", S),
        col("Result", "Result", S),
        col("Run At", "RunAt", DT, fmt="dd mmm yyyy hh:nn"),
    ], {"AffectedRows": "Int64.Type", "UnhandledRows": "Int64.Type"}),
    "Processing Status": ("vw_ProcessingStatus", "Support", "Last successful load and the status of the latest run.", [
        col("Last Success Run Id", "LastSuccessRunId", I, hidden=True),
        col("Last Success Mode", "LastSuccessMode", S),
        col("Last Success At", "LastSuccessAt", DT, fmt="dd mmm yyyy hh:nn"),
        col("Data As Of Date", "DataAsOfDate", D, fmt=DATE),
        col("Last Run Status", "LastRunStatus", S),
        col("Last Run Started At", "LastRunStartedAt", DT, fmt="dd mmm yyyy hh:nn"),
        col("Last Run Error", "LastRunError", S),
    ], {"LastSuccessRunId": "Int64.Type"}),
}

MONTHS = '{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}'

# Budget tables, prepared in Power Query from the finance workbook (rule R7)
BUDGET_SHEETS = f"""
let
    Source = Excel.Workbook ( File.Contents ( #"Budget File" ), null, true ),
    Sheets = Table.SelectRows ( Source, each [Kind] = "Sheet" and Text.StartsWith ( [Name], "FY" ) ),
    // rows 1 to 3 hold the title, a note and a blank line; row 4 holds the column names
    WithRows = Table.AddColumn ( Sheets, "Rows", each Table.PromoteHeaders ( Table.Skip ( [Data], 3 ), [PromoteAllScalars = true] ) ),
    WithYear = Table.AddColumn ( WithRows, "Year", each Number.From ( Text.End ( [Name], 4 ) ), Int64.Type ),
    Months = {MONTHS},
    Expanded = Table.ExpandTableColumn ( Table.SelectColumns ( WithYear, {{"Year", "Rows"}} ), "Rows", {{"Channel", "Region", "Category", "Measure"}} & Months ),
    Unpivoted = Table.UnpivotOtherColumns ( Expanded, {{"Year", "Channel", "Region", "Category", "Measure"}}, "Month", "Amount" ),
    Dated = Table.AddColumn ( Unpivoted, "MonthStart", each #date ( [Year], List.PositionOf ( Months, [Month] ) + 1, 1 ), type date ),
    Typed = Table.TransformColumnTypes ( Dated, {{{{"Channel", type text}}, {{"Region", type text}}, {{"Category", type text}}, {{"Measure", type text}}, {{"Amount", Currency.Type}}}} )
in
    Typed
"""

BUDGET = """
let
    Rows = Table.SelectRows ( #"Budget Sheets", each [Channel] <> "Total" ),
    Cleaned = Table.TransformColumns ( Rows, {{"Channel", each Text.Upper ( Text.Trim ( _ ) ), type text}, {"Region", each Text.Upper ( Text.Trim ( _ ) ), type text}, {"Category", Text.Trim, type text}} ),
    // category names as finance writes them, including misspellings seen in past workbooks; an unknown name stays
    // unmapped and is counted by the Unmapped Budget Rows measure
    CategoryMap = #table ( type table [Category = text, CategoryCode = text], {
        {"Whole Beans", "BEANS"}, {"Ground Coffee", "GROUND"}, {"Capsules", "CAPS"}, {"Capsule", "CAPS"},
        {"Gift Packs", "GIFT"}, {"Accessories", "ACCS"}, {"Accesories", "ACCS"}, {"Equipment", "EQUIP"} } ),
    Joined = Table.NestedJoin ( Cleaned, {"Category"}, CategoryMap, {"Category"}, "Map", JoinKind.LeftOuter ),
    Coded = Table.ExpandTableColumn ( Joined, "Map", {"CategoryCode"} ),
    Kept = Table.SelectColumns ( Coded, {"MonthStart", "Channel", "Region", "Category", "CategoryCode", "Measure", "Amount"} ),
    Pivoted = Table.Pivot ( Kept, {"Net revenue", "Gross profit"}, "Measure", "Amount", List.Sum ),
    Renamed = Table.RenameColumns ( Pivoted, {{"Channel", "ChannelCode"}, {"Region", "RegionCode"}, {"Category", "SheetCategory"}, {"Net revenue", "NetRevenue"}, {"Gross profit", "GrossProfit"}} ),
    Typed = Table.TransformColumnTypes ( Renamed, {{"CategoryCode", type text}, {"NetRevenue", Currency.Type}, {"GrossProfit", Currency.Type}} )
in
    Typed
"""

BUDGET_TOTAL = """
let
    Rows = Table.SelectRows ( #"Budget Sheets", each [Channel] = "Total" ),
    Kept = Table.SelectColumns ( Rows, {"MonthStart", "Measure", "Amount"} )
in
    Kept
"""

BUDGET_TABLES = {
    "Budget": ("Facts", "Monthly budget by channel, region and category, from the finance workbook (rule R7). Title rows and the "
               "workbook Total row are skipped; region codes are upper-cased and category names mapped to codes.", BUDGET, [
        col("Month Start", "MonthStart", D, hidden=True, fmt=DATE),
        col("Channel Code", "ChannelCode", S, hidden=True),
        col("Region Code", "RegionCode", S, hidden=True),
        col("Sheet Category", "SheetCategory", S, desc="Category name as written in the workbook."),
        col("Category Code", "CategoryCode", S, hidden=True),
        col("Net Revenue", "NetRevenue", M, hidden=True, fmt=MONEY),
        col("Gross Profit", "GrossProfit", M, hidden=True, fmt=MONEY),
    ]),
    "Budget Workbook Total": ("Support", "The Total row of each budget sheet, kept only to reconcile the prepared budget with the workbook.", BUDGET_TOTAL, [
        col("Month Start", "MonthStart", D, fmt=DATE),
        col("Measure", "Measure", S),
        col("Amount", "Amount", M, fmt=MONEY),
    ]),
}

# Measures: (name, folder, format, description, DAX)
MEASURES = []


def measure(name, folder, fmt, desc, expr):
    MEASURES.append((name, folder, fmt, desc, expr))


F_SALES, F_PROFIT, F_BUDGET, F_ORDERS, F_TIME, F_DQ, F_REPORT = (
    "1. Sales", "2. Profitability", "3. Budget", "4. Orders", "5. Time Comparison", "6. Data Quality", "7. Report")
EUR = "€ #,##0"
PCT = "0.0%"
PP = '+0.0" pp";-0.0" pp";0.0" pp"'
CHANGE = "+0.0%;-0.0%;0.0%"
BY_SALE_DATE = "USERELATIONSHIP ( 'Sales'[Original Invoice Date], 'Date'[Date] )"

measure("Gross Sales", F_SALES, EUR, "Quantity times list price on invoice lines, before discounts (R2). Invoice date.",
        "SUM ( 'Sales'[Gross Sales] )")
measure("Discounts", F_SALES, EUR, "Line discounts, contract plus promotion, applied once (R2). Invoice date.",
        "SUM ( 'Sales'[Discount Amount] )")
measure("Net Sales Before Returns", F_SALES, EUR, "Gross sales minus discounts.",
        "[Gross Sales] - [Discounts]")
measure("Returns", F_SALES, EUR, "Net value of credit note lines, in the month of the credit note (R4).",
        "SUM ( 'Sales'[Return Amount] )")
measure("Net Revenue", F_SALES, EUR, "Gross sales minus discounts minus returns, excluding VAT (R2). Invoice and credit note dates.",
        "SUM ( 'Sales'[Net Revenue] )")
measure("Units Sold", F_SALES, "#,##0", "Units on invoice lines.",
        "CALCULATE ( SUM ( 'Sales'[Quantity] ), KEEPFILTERS ( 'Sales'[Line Type] = \"Invoice\" ) )")
measure("Invoiced Orders", F_SALES, "#,##0", "Orders with an invoice in the period.",
        "CALCULATE ( DISTINCTCOUNT ( 'Sales'[Order Id] ), KEEPFILTERS ( 'Sales'[Line Type] = \"Invoice\" ) )")
measure("Average Order Value", F_SALES, "€ #,##0.00",
        "Net revenue divided by invoiced orders (R8). Blank unless a single channel is in context: business and consumer orders are never averaged together.", """
VAR Channels = CALCULATE ( DISTINCTCOUNT ( 'Sales'[Channel Code] ), KEEPFILTERS ( 'Sales'[Line Type] = "Invoice" ) )
RETURN
    IF ( Channels = 1, DIVIDE ( [Net Revenue], [Invoiced Orders] ) )""")
measure("Discount Rate %", F_SALES, PCT, "Discounts divided by gross sales.",
        "DIVIDE ( [Discounts], [Gross Sales] )")
measure("Return Rate %", F_SALES, PCT,
        "Returns of the sales invoiced in the period divided by their net sales before returns: each return is attributed to its original sale (R4).",
        f"DIVIDE ( CALCULATE ( [Returns], {BY_SALE_DATE} ), [Net Sales Before Returns] )")

measure("COGS", F_PROFIT, EUR,
        "Standard cost of the invoice month times units (R5). Returned equipment and accessories reverse their cost; returned coffee is written off.",
        "SUM ( 'Sales'[COGS] )")
measure("Gross Profit", F_PROFIT, EUR, "Net revenue minus COGS (R6).",
        "[Net Revenue] - [COGS]")
measure("Gross Margin %", F_PROFIT, PCT, "Gross profit divided by net revenue (R6).",
        "DIVIDE ( [Gross Profit], [Net Revenue] )")

BUDGET_GUARD = """
VAR OutsideBudgetGrain =
    ISCROSSFILTERED ( 'Customer' ) || ISCROSSFILTERED ( 'Product' ) || ISFILTERED ( 'Sales' ) || ISFILTERED ( 'Order Line' )"""
measure("Budget Net Revenue", F_BUDGET, EUR,
        "Budgeted net revenue (R7). Blank when customers, products or sales attributes are filtered: the budget only exists by month, channel, region and category.", f"""
{BUDGET_GUARD}
RETURN
    IF ( NOT OutsideBudgetGrain, SUM ( 'Budget'[Net Revenue] ) )""")
measure("Budget Gross Profit", F_BUDGET, EUR, "Budgeted gross profit (R7), with the same grain rule as Budget Net Revenue.", f"""
{BUDGET_GUARD}
RETURN
    IF ( NOT OutsideBudgetGrain, SUM ( 'Budget'[Gross Profit] ) )""")
measure("Budget Gross Margin %", F_BUDGET, PCT, "Budgeted gross profit divided by budgeted net revenue.",
        "DIVIDE ( [Budget Gross Profit], [Budget Net Revenue] )")
measure("Net Revenue vs Budget", F_BUDGET, "+€ #,##0;-€ #,##0;€ 0", "Net revenue minus budgeted net revenue.",
        "IF ( NOT ISBLANK ( [Budget Net Revenue] ), [Net Revenue] - [Budget Net Revenue] )")
measure("Net Revenue Attainment %", F_BUDGET, PCT, "Net revenue divided by budgeted net revenue.",
        "DIVIDE ( [Net Revenue], [Budget Net Revenue] )")
measure("Gross Profit vs Budget", F_BUDGET, "+€ #,##0;-€ #,##0;€ 0", "Gross profit minus budgeted gross profit.",
        "IF ( NOT ISBLANK ( [Budget Gross Profit] ), [Gross Profit] - [Budget Gross Profit] )")
measure("Gross Profit Attainment %", F_BUDGET, PCT, "Gross profit divided by budgeted gross profit.",
        "DIVIDE ( [Gross Profit], [Budget Gross Profit] )")

measure("Orders", F_ORDERS, "#,##0", "Orders placed in the period, whatever their status. Order date (R1).",
        "DISTINCTCOUNT ( 'Order Line'[Order Id] )")
measure("Order Value", F_ORDERS, EUR, "Value of the orders placed, net of line discounts. Order date.",
        "SUM ( 'Order Line'[Order Value] )")
measure("Cancelled Orders", F_ORDERS, "#,##0", "Orders placed in the period and cancelled before invoicing (R3).",
        "CALCULATE ( [Orders], KEEPFILTERS ( 'Order Line'[Order Status] = \"Cancelled\" ) )")
measure("Cancelled Order Value", F_ORDERS, EUR, "Value of the cancelled orders: never revenue (R3).",
        "CALCULATE ( [Order Value], KEEPFILTERS ( 'Order Line'[Order Status] = \"Cancelled\" ) )")
measure("Cancellation Rate %", F_ORDERS, PCT, "Cancelled orders divided by orders placed.",
        "DIVIDE ( [Cancelled Orders], [Orders] )")
measure("Open Orders", F_ORDERS, "#,##0", "Orders not invoiced at the data cut.",
        "CALCULATE ( [Orders], KEEPFILTERS ( 'Order Line'[Order Status] = \"Open\" ) )")

for kpi, rate in [("Net Revenue", False), ("Gross Profit", False), ("Gross Margin %", True)]:
    measure(f"{kpi} PY", F_TIME, PCT if rate else EUR, f"{kpi} in the same period of the previous year.",
            f"CALCULATE ( [{kpi}], SAMEPERIODLASTYEAR ( 'Date'[Date] ) )")
    change = "( CurrentValue - PriorValue ) * 100" if rate else "DIVIDE ( CurrentValue - PriorValue, PriorValue )"
    name = "Gross Margin YoY (pp)" if rate else f"{kpi} YoY %"
    measure(name, F_TIME, PP if rate else CHANGE,
            f"Change of {kpi} against the same period of the previous year{', in percentage points' if rate else ''}.", f"""
VAR CurrentValue = [{kpi}]
VAR PriorValue = [{kpi} PY]
RETURN
    IF ( NOT ISBLANK ( CurrentValue ) && NOT ISBLANK ( PriorValue ), {change} )""")
for kpi in ["Net Revenue", "Gross Profit"]:
    measure(f"{kpi} PM", F_TIME, EUR, f"{kpi} in the previous month.",
            f"CALCULATE ( [{kpi}], DATEADD ( 'Date'[Date], -1, MONTH ) )")
    measure(f"{kpi} MoM %", F_TIME, CHANGE, f"Change of {kpi} against the previous month.", f"""
VAR CurrentValue = [{kpi}]
VAR PriorValue = [{kpi} PM]
RETURN
    IF ( NOT ISBLANK ( CurrentValue ) && NOT ISBLANK ( PriorValue ), DIVIDE ( CurrentValue - PriorValue, PriorValue ) )""")

measure("Failed Checks", F_DQ, "#,##0", "Data quality checks that failed in the last run.",
        "CALCULATE ( COUNTROWS ( 'Data Quality Check' ), 'Data Quality Check'[Result] = \"Fail\" ) + 0")
measure("Lines With Carried-Forward Cost", F_DQ, "#,##0", "Sales lines costed with an earlier month's standard cost (SRC-02).",
        "CALCULATE ( COUNTROWS ( 'Sales' ), 'Sales'[Is Cost Carried Forward] = TRUE () ) + 0")
measure("Net Revenue Unknown Region", F_DQ, EUR, "Net revenue of customers exported without a region (SRC-05); outside every regional budget.",
        "CALCULATE ( [Net Revenue], 'Region'[Region Code] = \"UNK\" )")
measure("Unmapped Budget Rows", F_DQ, "#,##0", "Budget rows whose category name in the workbook matches no category.",
        "COUNTROWS ( FILTER ( 'Budget', ISBLANK ( 'Budget'[Category Code] ) ) ) + 0")
measure("Budget Workbook Difference", F_DQ, EUR,
        "Net revenue on the workbook Total rows minus the prepared budget, all years. Zero when Power Query kept every budget row.", """
VAR WorkbookTotal =
    CALCULATE ( SUM ( 'Budget Workbook Total'[Amount] ), REMOVEFILTERS (), 'Budget Workbook Total'[Measure] = "Net revenue" )
VAR Prepared = CALCULATE ( SUM ( 'Budget'[Net Revenue] ), REMOVEFILTERS () )
RETURN
    WorkbookTotal - Prepared""")

measure("Data Status", F_REPORT, None, "Text for every page: data date, load time and the simulated-data notice.", """
VAR AsOf = MAX ( 'Processing Status'[Data As Of Date] )
VAR LoadedAt = MAX ( 'Processing Status'[Last Success At] )
VAR LastRun = MAX ( 'Processing Status'[Last Run Status] )
RETURN
    "Data as of " & FORMAT ( AsOf, "dd mmm yyyy" )
        & "  |  Loaded " & FORMAT ( LoadedAt, "dd mmm yyyy hh:nn" )
        & IF ( LastRun = "Failed", "  |  Warning: the latest load failed", "" )
        & "  |  Simulated data" """)
measure("Filter Context", F_REPORT, None, "Text under every page title: the year, channel, region and category in context.", """
VAR YearText =
    IF ( HASONEVALUE ( 'Date'[Year] ), "Year " & VALUES ( 'Date'[Year] ), IF ( ISFILTERED ( 'Date'[Year] ), "Several years", "All years" ) )
VAR ChannelText =
    IF ( ISFILTERED ( 'Channel'[Channel] ), CONCATENATEX ( VALUES ( 'Channel'[Channel] ), 'Channel'[Channel], ", ", 'Channel'[Channel] ), "All channels" )
VAR RegionText =
    IF ( ISFILTERED ( 'Region'[Region] ), CONCATENATEX ( VALUES ( 'Region'[Region] ), 'Region'[Region], ", ", 'Region'[Region] ), "All regions" )
VAR CategoryText =
    IF ( ISFILTERED ( 'Category'[Category] ), CONCATENATEX ( VALUES ( 'Category'[Category] ), 'Category'[Category], ", ", 'Category'[Category] ), "All categories" )
RETURN
    YearText & "  ·  " & ChannelText & "  ·  " & RegionText & "  ·  " & CategoryText""")

# (from table, from column, to table, to column, active)
RELATIONSHIPS = [
    ("Sales", "Posting Date", "Date", "Date", True),
    ("Sales", "Original Invoice Date", "Date", "Date", False),
    ("Sales", "Customer Key", "Customer", "Customer Key", True),
    ("Sales", "Product Key", "Product", "Product Key", True),
    ("Sales", "Channel Code", "Channel", "Channel Code", True),
    ("Sales", "Region Code", "Region", "Region Code", True),
    ("Sales", "Category Code", "Category", "Category Code", True),
    ("Order Line", "Order Date", "Date", "Date", True),
    ("Order Line", "Customer Key", "Customer", "Customer Key", True),
    ("Order Line", "Product Key", "Product", "Product Key", True),
    ("Order Line", "Channel Code", "Channel", "Channel Code", True),
    ("Order Line", "Region Code", "Region", "Region Code", True),
    ("Order Line", "Category Code", "Category", "Category Code", True),
    ("Budget", "Month Start", "Date", "Date", True),
    ("Budget", "Channel Code", "Channel", "Channel Code", True),
    ("Budget", "Region Code", "Region", "Region Code", True),
    ("Budget", "Category Code", "Category", "Category Code", True),
]


def column_lines(table, c):
    o = []
    if c["desc"]:
        o.append(f"{T}/// {c['desc']}")
    o.append(f"{T}column {q(c['name'])}")
    o.append(f"{T * 2}dataType: {c['dtype']}")
    if c["hidden"]:
        o.append(f"{T * 2}isHidden")
    if c["key"]:
        o.append(f"{T * 2}isKey")
    if c["fmt"]:
        o.append(f"{T * 2}formatString: {c['fmt']}")
    o.append(f"{T * 2}lineageTag: {tag('c/' + table + '/' + c['name'])}")
    o.append(f"{T * 2}summarizeBy: none")
    o.append(f"{T * 2}sourceColumn: {c['src']}")
    if c["sort"]:
        o.append(f"{T * 2}sortByColumn: {q(c['sort'])}")
    o += ["", f"{T * 2}annotation SummarizationSetBy = Explicit", ""]
    return o


def table_tmdl(name, desc, columns, group, m_source, category=None):
    o = [f"/// {desc}", f"table {q(name)}", f"{T}lineageTag: {tag('t/' + name)}"]
    if category:
        o.append(f"{T}dataCategory: {category}")
    o.append("")
    for c in columns:
        o += column_lines(name, c)
    o += [f"{T}partition {q(name)} = m", f"{T * 2}mode: import", f"{T * 2}queryGroup: {group}", f"{T * 2}source =",
          indent(m_source, 4), "", f"{T}annotation PBI_ResultType = Table"]
    return "\n".join(o)


def view_query(view, types):
    steps = ["Source = Sql.Database ( Server, Database ),", f'Data = Source{{[Schema = "rpt", Item = "{view}"]}}[Data],']
    pairs = ", ".join(f'{{"{k}", {v}}}' for k, v in types.items())
    steps.append(f"Typed = Table.TransformColumnTypes ( Data, {{{pairs}}} )")
    return "let\n" + "\n".join("    " + s for s in steps) + "\nin\n    Typed"


def measures_tmdl():
    o = ["/// Home of all report measures. KPI definitions: docs/04-kpi-dictionary.md.", "table _Measures",
         f"{T}lineageTag: {tag('t/_Measures')}", ""]
    for name, folder, fmt, desc, expr in MEASURES:
        o.append(f"{T}/// {desc}")
        if "\n" in expr.strip():
            o += [f"{T}measure {q(name)} =", indent(expr, 3)]
        else:
            o.append(f"{T}measure {q(name)} = {expr.strip()}")
        if fmt:
            o.append(f"{T * 2}formatString: {fmt}")
        o += [f"{T * 2}displayFolder: {folder}", f"{T * 2}lineageTag: {tag('m/' + name)}", ""]
    o += [f"{T}column Value", f"{T * 2}dataType: int64", f"{T * 2}isHidden", f"{T * 2}lineageTag: {tag('c/_Measures/Value')}",
          f"{T * 2}summarizeBy: none", f"{T * 2}sourceColumn: Value", "", f"{T * 2}annotation SummarizationSetBy = Explicit", "",
          f"{T}partition _Measures = m", f"{T * 2}mode: import", f"{T * 2}queryGroup: Support", f"{T * 2}source =",
          f"{T * 4}let", f"{T * 4}    Source = #table ( type table [Value = Int64.Type], {{}} )", f"{T * 4}in", f"{T * 4}    Source",
          "", f"{T}annotation PBI_ResultType = Table"]
    return "\n".join(o)


def parameter(name, value, desc):
    return "\n".join([f"/// {desc}",
                      f'expression {q(name)} = "{value}" meta [IsParameterQuery = true, Type = "Text", IsParameterQueryRequired = true]',
                      f"{T}lineageTag: {tag('e/' + name)}", f"{T}queryGroup: Parameters", "", f"{T}annotation PBI_ResultType = Text", ""])


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text.rstrip("\n") + "\n", encoding="utf-8", newline="\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("--budget-file", default=str(REPO / "data" / "generated" / "budget" / "Velmora_Budget_FY2023-2025.xlsx"))
    args = parser.parse_args()

    definition = MODEL / "definition"
    for old in (definition / "tables").glob("*.tmdl"):
        old.unlink()

    for name, (view, group, desc, columns, types) in TABLES.items():
        write(definition / "tables" / f"{name}.tmdl",
              table_tmdl(name, desc, columns, group, view_query(view, types), "Time" if name == "Date" else None))
    for name, (group, desc, m_source, columns) in BUDGET_TABLES.items():
        write(definition / "tables" / f"{name}.tmdl", table_tmdl(name, desc, columns, group, m_source))
    write(definition / "tables" / "_Measures.tmdl", measures_tmdl())

    o = []
    for from_table, from_col, to_table, to_col, active in RELATIONSHIPS:
        o.append(f"relationship {tag('r/' + from_table + '/' + from_col)}")
        if not active:
            o.append(f"{T}isActive: false")
        o += [f"{T}fromColumn: {q(from_table)}.{q(from_col)}", f"{T}toColumn: {q(to_table)}.{q(to_col)}", ""]
    write(definition / "relationships.tmdl", "\n".join(o))

    budget_file = args.budget_file.replace('"', '""')   # M escapes quotes by doubling them; backslashes are literal
    write(definition / "expressions.tmdl", "\n".join([
        parameter("Server", "localhost", "SQL Server instance that hosts VelmoraSales."),
        parameter("Database", "VelmoraSales", "Database with the rpt views."),
        parameter("Budget File", budget_file, "Full path of the finance budget workbook (build.ps1 sets it to this clone)."),
        "/// Every budget sheet, unpivoted to one row per channel, region, category, measure and month. Staging query, not loaded.",
        "expression 'Budget Sheets' =",
        indent(BUDGET_SHEETS, 2),
        f"{T}lineageTag: {tag('e/Budget Sheets')}",
        f"{T}queryGroup: Support",
        "",
        f"{T}annotation PBI_ResultType = Table",
    ]))

    all_tables = list(TABLES) + list(BUDGET_TABLES) + ["_Measures"]
    order = ["Server", "Database", "Budget File", "Budget Sheets"] + [t for t in all_tables if t != "_Measures"]
    write(definition / "model.tmdl", "\n".join([
        "model Model", f"{T}culture: en-US", f"{T}defaultPowerBIDataSourceVersion: powerBI_V3", f"{T}discourageImplicitMeasures",
        f"{T}sourceQueryCulture: en-US", f"{T}dataAccessOptions", f"{T * 2}legacyRedirects", f"{T * 2}returnErrorValuesAsNull", "",
        "queryGroup Parameters", "", f"{T}annotation PBI_QueryGroupOrder = 0", "",
        "queryGroup Dimensions", "", f"{T}annotation PBI_QueryGroupOrder = 1", "",
        "queryGroup Facts", "", f"{T}annotation PBI_QueryGroupOrder = 2", "",
        "queryGroup Support", "", f"{T}annotation PBI_QueryGroupOrder = 3", "",
        "annotation __PBI_TimeIntelligenceEnabled = 0", "",
        "annotation PBI_QueryOrder = [" + ",".join(f'"{x}"' for x in order) + "]", "",
    ] + [f"ref table {q(t)}" for t in all_tables]))
    write(definition / "database.tmdl", f"database VelmoraSales\n{T}compatibilityLevel: 1702\n")

    write(MODEL / "definition.pbism", """{
  "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/semanticModel/definitionProperties/1.0.0/schema.json",
  "version": "4.2",
  "settings": {}
}""")
    write(MODEL / ".platform", f"""{{
  "$schema": "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json",
  "metadata": {{
    "type": "SemanticModel",
    "displayName": "VelmoraSales"
  }},
  "config": {{
    "version": "2.0",
    "logicalId": "{tag('model/VelmoraSales')}"
  }}
}}""")
    print(f"{len(all_tables)} tables, {len(MEASURES)} measures, {len(RELATIONSHIPS)} relationships -> {MODEL}")


if __name__ == "__main__":
    main()
