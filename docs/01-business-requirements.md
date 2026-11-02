# Business Requirements

> **SIMULATED SCENARIO.** Velmora Coffee Roasters S.L., its customers, data and every figure are fictional.

Version 1.1, 2026-11-02: version 1.0 (approved 2026-11-01 by the Chief Financial Officer, fictional sponsor) plus
change requests CR-01 to CR-03 (`docs/02-change-log.md`).

## 1. The company

Velmora Coffee Roasters is a specialty coffee roaster based in Valencia, Spain: about 95 employees and around
€20 million of net revenue a year. It sells about 95 products (whole beans, ground coffee, compatible capsules,
gift packs, accessories and equipment such as grinders and espresso machines) through three channels:

| Channel | Customers | How it works |
|---|---|---|
| HoReCa | Cafés, restaurants, hotels | Contract discount by customer tier (Gold, Silver, Bronze); weekly orders |
| Retail | Supermarket chains and gourmet shops (one customer per store) | Large orders, funded promotions, returns of damaged or expiring stock |
| E-commerce | Consumers | Campaigns (Black Friday, Christmas, summer); equipment may be returned within 14 days |

## 2. The problem

Revenue grew over the last two years but gross profit did not follow. The price of green coffee rose, and nobody
can say how much of the gap comes from cost, product mix, discounts or returns. The monthly close is built from
three spreadsheets that do not agree, and the budget arrives as an Excel file, so actual versus budget is not
compared reliably.

## 3. Users and use

| Users | Use |
|---|---|
| CEO and CFO | Monthly close |
| Sales director and regional managers | Weekly review |

## 4. Business questions

1. How much do we sell and how much is left, by month, channel, region, category and customer?
2. Are we meeting the revenue and gross profit budget, and where are we missing it?
3. Why did the margin fall: cost, product mix, discounts or returns?
4. Which products, customers and regions bring profit, and which only bring volume?
5. Are discounts and returns under control in each channel?

## 5. KPIs in scope (version 1)

Gross sales, discounts, returns, net revenue, cost of goods sold (COGS), gross profit, gross margin %, budget and
attainment for net revenue and gross profit, orders, units, average order value by channel, discount rate,
return rate, cancellations, month-over-month and year-over-year changes.

Added in version 1.1: discount above the contract policy and share of lines above it (CR-01), gross margin bridge
against the previous year (CR-02), gross profit per promotion day against ordinary days (CR-03).

## 6. Approved calculation rules

| # | Topic | Rule |
|---|---|---|
| R1 | Revenue date | Revenue is recognised on the **invoice date** (shipment). Orders are analysed by order date. An order placed on 31 December and invoiced on 3 January counts in January. |
| R2 | Gross and net | **Gross sales** = quantity × list price. **Discounts** = line discount (contract plus promotion), applied once. **Net revenue** = gross sales − discounts − returns. All amounts **exclude VAT**. Freight is out of scope in version 1. |
| R3 | Cancellations | An order cancelled before invoicing **never becomes revenue**; it only counts as a cancellation. After invoicing, only a return (credit note) can reduce revenue. |
| R4 | Returns | A return reduces net revenue in the **month of the credit note** (finance view, matches the accounts). The **return rate by product** is attributed to the original sale. |
| R5 | Cost | **Standard cost of the invoice month** (a monthly cost table that follows green coffee prices). On a return, equipment goes back to stock (cost reversed); coffee and food are written off (cost not reversed). |
| R6 | Margin | Gross profit = net revenue − COGS. Gross margin % = gross profit ÷ net revenue. Freight and commissions are out of scope (version 2). |
| R7 | Budget | Monthly by channel × region × category, for net revenue and gross profit. Delivered by finance as an **Excel workbook**, prepared in Power Query. |
| R8 | Average order value | Net revenue ÷ invoiced orders, **always by channel**: business and consumer orders are never averaged together. |
| R9 | Discount policy (CR-01) | The contract discount of each channel and customer segment has a maximum (`ref.DiscountPolicy`). Invoice lines of orders **without a campaign** are checked against it, free samples (100 % discount) excluded: campaigns and promotions add discount on top of the contract. Discount above policy = gross sales × (line discount − maximum). |
| R10 | Margin bridge (CR-02) | The change of gross margin % against the previous year is split, by product × channel, into mix, standard cost, list price, discount rate, new and discontinued products, and returns; the parts add up to the change. |
| R11 | Promotion profitability (CR-03) | Marketing's promotion calendar (`ref.Promotion`) names the channel, category and days of each promotion. A promotion day is compared with the other days of the same month for the same channel and category: gross profit per order day, by order date. |

## 7. Out of scope (version 2)

Customer analytics (retention, RFM, churn), contribution margin with freight and commissions, sales forecasting,
scheduling of the refresh (SQL Server Agent, Power BI Service, gateway).

## 8. Acceptance criteria

| # | Criterion |
|---|---|
| AC-01 | One command rebuilds the database and the data from zero. |
| AC-02 | Every KPI has a documented rule, grain and period (`docs/04-kpi-dictionary.md`). |
| AC-03 | The main KPIs in Power BI match independent SQL queries on the source tables. |
| AC-04 | The data quality checks pass, with every known source defect handled by a documented rule. |
| AC-05 | The scheduled processing is safe to re-run: running it twice, or after new source changes, gives the same result as a full reload. |
| AC-06 | Actual versus budget works for revenue and gross profit at the budget grain. |
| AC-07 | Screenshots in the documentation are taken from the report open in Power BI Desktop. |
