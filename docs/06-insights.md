# Insights and Recommendations

> **SIMULATED SCENARIO.** Velmora Coffee Roasters and all its data are fictional. The data generator was built
> with these patterns on purpose (`TECHNICAL_DECISIONS.md`, D-01); this document shows how the solution finds and
> measures them. One expected pattern did not show up as assumed (finding 1, mix).

Queries: `analysis/margin_bridge.sql`, `analysis/insights.sql` (SQL on dw) and `analysis/budget_gap.dax` (DAX
on the model, because the budget exists only in the workbook). Figures are for 2023 to 2025.

## 1. The margin fell because of cost; prices recovered about a quarter of it

Gross margin went from 48.9 % (2023) to 44.1 % (2024) and 42.0 % (2025). Bridge from 2023 to 2025, in
percentage points, at product × channel level:

| Part | pp |
|---|---|
| Gross margin 2023 | 48.90 |
| Mix (product × channel) | +0.60 |
| Standard cost | −10.31 |
| List price | +2.83 |
| Discount rate | +0.05 |
| New and discontinued products | −0.05 |
| Returns | −0.03 |
| Gross margin 2025 | 41.99 |

- Standard cost explains the whole fall. The 7 % list price increase of 2025 recovered 2.8 of the 10.3 points.
- Mix helped. E-commerce grew faster than the other channels and, even with more equipment, keeps the highest
  margin (51 % in 2025, against 46 % in HoReCa and 35 % in Retail). The expected story, "e-commerce equipment is
  dragging the margin down", is not what the data shows at company level.
- Discounts and returns did not move the total margin. They matter in specific places (findings 3 and 4).

## 2. Revenue beats the budget; gross profit misses it because the budget assumes last year's margin

| Year | Net revenue vs budget | Gross profit vs budget | of which volume | of which margin |
|---|---|---|---|---|
| 2024 | +€493k | −€565k | +€290k | −€855k |
| 2025 | +€641k | −€152k | +€321k | −€473k |

Volume = (revenue − budget revenue) × budget margin; margin = revenue × (actual − budget margin). Finance plans
each cell with the previous year's margin, so a cost increase that is already visible at planning time reaches
the budget a year late. Retail carries most of the miss (−€475k in 2024, −€274k in 2025).

**Recommendation for finance:** plan gross profit with the standard costs expected for the budget year, not
with the previous year's margin.

## 3. Retail raised prices five months after the other channels

Coffee list prices rose 7 % in February 2025 in HoReCa and e-commerce, and in July in Retail. Estimate, assuming
the same volumes and discounts: had Retail moved in February, its coffee orders of February to June
(€2.45M of net sales) would have brought about **€172k** more gross profit, against a Retail gross profit miss of
€274k in 2025. Volume response to the price was not modelled.

## 4. HoReCa discounts in Andalusia exceed the contract policy

The contract policy caps HoReCa discounts by tier (Gold 12 %, Silver 8 %, Bronze 4 %). Free samples (100 %
discount) left aside:

| Year | Andalusia discount rate | Other regions | Andalusia lines above policy | Discount above policy |
|---|---|---|---|---|
| 2023 | 10.8 % | 6.2 % to 6.6 % | 63 % | €59k |
| 2024 | 10.8 % | 6.3 % to 6.7 % | 61 % | €61k |
| 2025 | 10.8 % | 6.3 % to 6.6 % | 62 % | €72k |

No other region has lines above policy. Customers without region (SRC-05) show a few (11 % to 14 % of their
lines), likely Andalusian customers whose region is missing.

**Recommendation for sales:** review discount approval in Andalusia; fix the region of the 30 customers
without one.

## 5. Retail capsule promotions lose gross profit

Retail capsules run a promotion on days 1 to 10 of March, May, September and November (25 % extra discount).
Compared with the other days of the same months, by order date:

| Year | Units per day, promotion | Units per day, rest | Margin, promotion | Margin, rest | Gross profit per day, promotion | rest |
|---|---|---|---|---|---|---|
| 2023 | 2,060 | 1,102 | 21.0 % | 41.7 % | €1,406 | €1,972 |
| 2024 | 2,041 | 1,119 | 15.2 % | 37.3 % | €993 | €1,820 |
| 2025 | 1,969 | 1,108 | 12.0 % | 34.8 % | €783 | €1,739 |

Promotions almost double the volume but bring less gross profit per day than ordinary days, and the gap widened
as cost rose: in 2025 a promotion day earned 45 % of an ordinary day. At 2025 costs a promotion day would need
about 3.9 times the ordinary volume (€0.40 instead of €1.57 gross profit per unit) to earn as much. Whether promotions bring new shoppers or retailer listing benefits
is outside the data.

**Recommendation for marketing:** reduce the promotional discount or limit it to SKUs whose margin can absorb it.

The table counts invoice lines by order year. The report KPIs of CR-03 follow the report's posting-date filter and
include returns, so for 2025 they show €764 per promotion day and €1,698 per ordinary day (45.0 %) instead of
€783 and €1,739 (45.0 %).

## 6. E-commerce sells more equipment, with lower margin and more returns

| Sale year | Equipment share of e-commerce sales | Equipment margin | Other e-commerce margin | Equipment return rate |
|---|---|---|---|---|
| 2023 | 22.7 % | 35.4 % | 63.4 % | 5.9 % |
| 2024 | 37.8 % | 37.3 % | 60.8 % | 8.6 % |
| 2025 | 42.4 % | 37.8 % | 60.4 % | 8.6 % |

Equipment returns go back to stock (cost reversed), so their cost is the lost sale and handling, not written-off
goods. Worth monitoring; not a cause of the company margin fall (finding 1).

## Report changes (approved 2026-11-02)

The proposals below were presented to the client, approved and implemented as requirements version 1.1
(`docs/02-change-log.md`). They are on the report page **Profit Levers**.

| ID | Change | Why |
|---|---|---|
| CR-01 | KPIs **Discount Above Policy** (€) and **Lines Above Policy %** (rule R9), by region and HoReCa tier | Makes finding 4 visible every month instead of in an ad hoc query |
| CR-02 | **Margin bridge** waterfall from the previous year (rule R10), following the report filters | Answers business question 3 in the report itself |
| CR-03 | **Gross profit per promotion day** against ordinary days (rule R11), from the promotion calendar | Lets marketing judge each promotion window |

The figures of the KPIs match the analysis above; `docs/05-validation-results.md` lists the checks.
