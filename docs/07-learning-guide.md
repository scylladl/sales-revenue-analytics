# Learning Guide

> **SIMULATED SCENARIO.** Velmora Coffee Roasters and all its data are fictional.

A path through the project for someone who wants to understand how it was built, in the order the work was done.
Each step names the files to read and one thing to try.

## 1. Requirements before data

Read `docs/01-business-requirements.md`. The eight rules (R1 to R8) decide every number later: which date a sale
belongs to, what "net" means, what happens to a cancelled order or a returned machine.
*Try:* for an order placed on 31 December, invoiced on 3 January and half returned on 20 January, write down in
which month each amount lands and why.

## 2. Source data with known problems

Read `generator/generate_data.py` (top docstring and `add_defects`) and `docs/03-data-model.md`, "Source defects".
*Try:* run the generator with another seed and compare `data/generated/defects.json`.

## 3. Database layers

Read the numbered scripts in `database/` in order. `02_source_tables.sql` is the ERP as it is; `03_dw_tables.sql`
is the model for analysis; the comments on `dw.FactSales` explain the sign of each amount on return rows.
*Try:* find one credit note in `src.CreditNoteLine` and follow it to its row in `dw.FactSales`.

## 4. The incremental load

Read `database/04_load_procedure.sql`: watermarks, the list of changes that mark an order as affected, the
`MERGE` with `NOT MATCHED BY SOURCE`, the application lock, the run log. Then read
`tests/test_incremental_load.ps1` and `tests/simulate_erp_changes.sql`.
*Try:* remove the standard cost condition from the affected-orders list and run the test. The full reload should
now find rows the incremental load missed.

## 5. Data quality

Read `database/05_dq_checks.sql`. Source checks pass when a defect is handled, not when it is absent;
integrity checks fail on any affected row.
*Try:* add a check for invoice lines priced differently from the price list of the order date.

## 6. Semantic model and Power Query

Read `powerbi/generate_model.py`: the table list mirrors the `rpt` views; the budget queries show how a messy
workbook becomes a table (skip rows, unpivot, map names, pivot measures); the measures follow
`docs/04-kpi-dictionary.md`.
*Try:* open the model in Power BI Desktop, add a fourth category misspelling to the workbook and watch
`Unmapped Budget Rows`.

## 7. Report

Read `powerbi/build_report.py` and compare it with `docs/screenshots/`. `TECHNICAL_DECISIONS.md`, D-08, lists the
four problems that only showed up on screen.
*Try:* remove the customer id from the top-customers table and see which customers appear.

## 8. Proving the numbers

Read `validation/kpi_source.sql`: the same KPIs computed from `src` without dw. `validation/validate_kpis.ps1`
compares them with the model.
*Try:* change the rounding of the discount in the SQL to round only the total, and see which comparisons fail.

## 9. From numbers to recommendations

Read `analysis/margin_bridge.sql` and `docs/06-insights.md`. The bridge splits a margin change into parts that add
up exactly; the budget gap is split into volume and margin in DAX because the budget never enters SQL.
*Try:* run the bridge from 2024 to 2025 and explain why the list price part is positive only in that year.
