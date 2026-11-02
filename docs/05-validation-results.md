# Validation Results

> **SIMULATED SCENARIO.** Velmora Coffee Roasters and all its data are fictional.

What was tested, how, and what remains to be checked by hand. Runs of 2026-11-01 and 2026-11-02 on SQL Server
2025 Developer (local) and Power BI Desktop (Microsoft Store version), data generated with seed 7.

## Summary

| Acceptance criterion | Test | Result |
|---|---|---|
| AC-01 One command rebuilds everything | `build.ps1` from generated data to model files | Pass (see below) |
| AC-02 Every KPI documented | `docs/04-kpi-dictionary.md` covers the 51 measures | Done |
| AC-03 KPIs match independent SQL | `validation/validate_kpis.ps1`: 231 comparisons | 231 of 231 match |
| AC-04 Data quality checks pass | `dq.usp_RunChecks`: 10 checks | 10 of 10 pass |
| AC-05 Safe to re-run; incremental = full reload | `tests/test_incremental_load.ps1`: 21 assertions | 21 of 21 pass |
| AC-06 Actual vs budget at the budget grain | Budget measures by year, channel, region, category; reconciliation with the workbook | Pass |
| AC-07 Screenshots from Power BI Desktop | `docs/screenshots/` taken with `pbir desktop screenshot` from the open report | Done |

## AC-01 Rebuild

`build.ps1` generates the data, deploys the database objects, loads the exports, runs a full load with the
checks and writes the semantic model: 45 s end to end on the development machine, all 10 checks passing. Run over
an existing database, its full load found 0 rows to insert, update or delete: the generator reproduces the same
data from the same seed. Separately measured: source load 22 s (505,846 order lines), full load into dw 12 to 14 s. The first version of the loader, in PowerShell, took 580 s for the same
files (`TECHNICAL_DECISIONS.md`, D-04).

## AC-03 SQL against Power BI

`validation/kpi_source.sql` recalculates 18 KPIs straight from the `src` tables, applying the rules without dw or
the load procedure (including the discount policy and promotion rules of version 1.1, from the `ref` tables).
`validation/validate_kpis.ps1` evaluates the same measures in the model open in Power BI Desktop and compares them
by year (2023 to 2025), for all channels and for each channel: 216 comparisons. It also compares the prepared
budget with the workbook's Total rows for each year (3), and the six steps of the Margin Bridge (pp) measure with
`analysis/margin_bridge.sql` for 2024 and 2025 (12). Amounts must match to the cent, ratios to 0.0001 and bridge
steps to 0.0002 pp. All 231 match; details in `validation/kpi_comparison.csv`.

Two defects were found this way and fixed before the comparison passed. The first version of the bridge measure
summed Currency columns, which keep four decimals, so the list price step showed 2.73 pp instead of 2.77 pp; the
amounts are now converted to DOUBLE. The SQL bridge itself used decimal division, whose scale reduction moved the
parts by up to 0.006 pp; it now uses float. Lines Above Policy % returned blank instead of 0 % for channels with no
line above policy.

| 2025, all channels | SQL on src | Power BI |
|---|---|---|
| Net Revenue | 18,249,738.09 | 18,249,738.09 |
| COGS | 10,586,485.42 | 10,586,485.42 |
| Gross Margin % | 41.99 % | 41.99 % |
| Return Rate % | 0.73 % | 0.73 % |
| Budget Net Revenue (workbook Total rows) | 17,608,300 | 17,608,300 |

Average Order Value for all channels is blank on both sides, as rule R8 requires.

The SQL side stops if an order line ever has more than one credit note line, because its return cap is written
for one credit line per order line (true for this data). The load procedure caps cumulative quantities.

## AC-04 Data quality

| Check | Affected | Unhandled | Result |
|---|---|---|---|
| SRC-01 Possible duplicate customers | 25 | 0 | Pass |
| SRC-02 Product-months without standard cost | 2 | 0 | Pass |
| SRC-03 Order lines credited above the invoiced units | 12 | 0 | Pass |
| SRC-04 Invoices dated before their order | 40 | 0 | Pass |
| SRC-05 Customers without region | 30 | 0 | Pass |
| INT-01 to INT-05 | 0 | 0 | Pass |

The source counts equal the defects the generator wrote (`data/generated/defects.json`).

## AC-05 Incremental load

`tests/test_incremental_load.ps1` starts from a full load, applies one day of simulated ERP activity
(`tests/simulate_erp_changes.sql`), runs the incremental load and then a full reload:

- the incremental run reprocessed 8,523 of 204,534 orders (inserted 165 sales rows, updated 574);
- the full reload over that result found **0 rows to insert, update or delete**, and the fact checksums,
  row counts, net revenue and COGS did not move;
- a second incremental run had nothing to do;
- specific cases behave as the rules say: newly invoiced orders become revenue on their invoice date, cancelled
  orders carry none, a returned machine reverses its cost, a second credit note on a fully returned line is
  capped to zero units, an added standard cost replaces the carried-forward one, a customer's move changes the
  region of its history, a product rename reaches the dimension;
- a load started while another holds the lock is refused and logged as failed;
- the test restores the database to the repository data at the end.

## Power BI checks

- The TMDL parses with the Tabular Object Model shipped with Power BI Desktop (`powerbi/validate_model.ps1`),
  which also rejects DAX variables named with reserved words.
- After loading in Desktop, every measure and partition is in state Ready; row counts equal the dw tables;
  the budget has 2,808 rows (3 years × 12 months × 78 channel-region-category cells), Budget Workbook
  Difference is 0 and Unmapped Budget Rows is 0.
- The six pages of both designs (light and dark) were rendered in Power BI Desktop and inspected from screenshots after every change.
  Problems found that way and fixed: the year filter was written as text and never matched the integer year;
  month axes were sorted by value; the KPI visual showed December instead of the year (replaced by cards);
  the top-customers table grouped customers by name, merging different customers with the same name
  (now grouped by customer id). After the redesign: theme defaults gave the rail buttons a title divider and
  border, and did not reach their fill and text (set per button); the combo chart drew the budget line with a
  shaded area over the revenue columns (area shading switched off for every visual type). The dark design showed
  that the sqlbi base theme fixes literal colours (white visual backgrounds, grey canvas, card values, table
  headers, cells and totals, axis labels, gridlines); the theme of both designs now sets each of them.

## Not tested or pending manual validation

- Interactions and cross-filtering were not exercised click by click; the screenshots show the default state
  (year 2025, no other filter). The navigation buttons are configured with page ids but were not clicked in
  Desktop.
- The report was not published to the Power BI Service, and no gateway or schedule was configured (out of scope).
- Accessibility (contrast, alt text, keyboard order) was not reviewed.
- Performance was not measured beyond the load timings above; no claim is made about report speed.
- The build was run on one machine. A clean machine needs SQL Server, ODBC Driver 18, Python and Power BI Desktop.
- The `Budget File` parameter is a placeholder in the repository; `build.ps1` sets it to the clone's path.
