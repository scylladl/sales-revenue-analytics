# KPI Dictionary

> **SIMULATED SCENARIO.** Velmora Coffee Roasters and all its data are fictional.

Every KPI is an explicit measure in the `_Measures` table of the semantic model. Rules R1 to R8 are in
`docs/01-business-requirements.md`. All amounts are in euros and exclude VAT.

**Dates.** Sales KPIs use the posting date: the invoice date for sales, the credit note date for returns (R1,
R4). Order KPIs use the order date. Budget KPIs use the budget month. Return Rate % uses the original sale date.

**Grain.** Sales KPIs can be cut by any dimension. Budget KPIs exist only by month, channel, region and
category; they return blank when customers, products or sales attributes are filtered. Average Order Value
exists only for one channel at a time.

## Sales

| Measure | Rule | Definition |
|---|---|---|
| Gross Sales | R2 | Quantity × list price on invoice lines |
| Discounts | R2 | Line discount (contract plus promotion), applied once |
| Net Sales Before Returns | R2 | Gross Sales − Discounts |
| Returns | R4 | Net value of credit note lines (returned units × list price × (1 − line discount)), in the credit note month; returned units never exceed invoiced units |
| Net Revenue | R2 | Gross Sales − Discounts − Returns |
| Units Sold | | Units on invoice lines |
| Invoiced Orders | R3 | Orders with an invoice in the period (distinct count) |
| Average Order Value | R8 | Net Revenue ÷ Invoiced Orders; blank unless a single channel is in context |
| Discount Rate % | | Discounts ÷ Gross Sales |
| Return Rate % | R4 | Returns of the sales invoiced in the period ÷ their Net Sales Before Returns |

## Profitability

| Measure | Rule | Definition |
|---|---|---|
| COGS | R5 | Units × standard cost of the invoice month (latest earlier month when a month is missing). Returned accessories and equipment reverse their cost; returned coffee does not. |
| Gross Profit | R6 | Net Revenue − COGS |
| Gross Margin % | R6 | Gross Profit ÷ Net Revenue |

## Budget

| Measure | Rule | Definition |
|---|---|---|
| Budget Net Revenue, Budget Gross Profit | R7 | Sum of the prepared budget rows |
| Budget Gross Margin % | | Budget Gross Profit ÷ Budget Net Revenue |
| Net Revenue vs Budget, Gross Profit vs Budget | | Actual − budget (blank where there is no budget) |
| Net Revenue Attainment %, Gross Profit Attainment % | | Actual ÷ budget. Shown in the report as "Revenue Attainment %" and "Profit Attainment %". |

## Orders

| Measure | Rule | Definition |
|---|---|---|
| Orders | R1 | Orders placed in the period, any status |
| Order Value | | Value of the orders placed, net of line discounts |
| Cancelled Orders, Cancelled Order Value | R3 | Orders placed in the period and cancelled before invoicing; never revenue |
| Cancellation Rate % | | Cancelled Orders ÷ Orders |
| Open Orders | | Orders not invoiced at the data cut |

## Time comparison

| Measure | Definition |
|---|---|
| Net Revenue PY, Gross Profit PY, Gross Margin % PY | Same period of the previous year (`SAMEPERIODLASTYEAR`) |
| Net Revenue YoY %, Gross Profit YoY % | Relative change against the previous year |
| Gross Margin YoY (pp) | Change in percentage points |
| Net Revenue PM, Gross Profit PM, Net Revenue MoM %, Gross Profit MoM % | Previous month and relative change |

Changes are blank when either period has no value, so the first year of data shows no YoY.

## Data quality and report

| Measure | Definition |
|---|---|
| Failed Checks | Checks with result Fail in the last `dq.usp_RunChecks` run |
| Lines With Carried-Forward Cost | Sales lines costed with an earlier month's standard cost (SRC-02) |
| Net Revenue Unknown Region | Net revenue of customers without region (SRC-05) |
| Unmapped Budget Rows | Budget rows whose category name matches no category |
| Budget Workbook Difference | Workbook Total rows − prepared budget, all years; 0 when Power Query kept every row |
| Data Status, Filter Context | Text lines in every page header |
