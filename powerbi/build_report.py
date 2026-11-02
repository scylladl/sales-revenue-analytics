"""
Builds the VelmoraSales report (powerbi/VelmoraSales.Report) from scratch through the pbir CLI.

Every page, visual, binding and filter is created with pbir commands, so the report can be rebuilt and reviewed as
code. The script recreates the report folder: manual edits made in Power BI Desktop are lost unless they are
copied here first. Close the report in Power BI Desktop before running it.

Usage: python powerbi/build_report.py
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
R = "VelmoraSales.Report"
PBIR = shutil.which("pbir") or str(Path.home() / "AppData/Roaming/Python/Python313/Scripts/pbir.exe")

# 1280 x 720 canvas: 24 px margins, 16 px gaps
M, G, W = 24, 16, 1232
HALF = (W - G) // 2
ROW_A, ROW_B, ROW_C = (124, 84), (224, 224), (464, 232)


def pbir(*args):
    result = subprocess.run([PBIR, "-q", *args], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if result.returncode != 0:
        sys.exit(f"pbir {' '.join(args)} failed:\n{(result.stdout + result.stderr)[-2000:]}")
    return result.stdout


def columns(count):
    width = (W - (count - 1) * G) // count
    return [(M + i * (width + G), width) for i in range(count)]


def card_row(cards):
    """cards: (visual name, measure), laid out in equal columns along the top row"""
    return [dict(visual_type="card", name=name, x=x, y=ROW_A[0], width=w, height=ROW_A[1], fields={"Values": f"_Measures.{measure}"})
            for (name, measure), (x, w) in zip(cards, columns(len(cards)))]


def visual(kind, name, title, slot, fields):
    x, y, w, h = slot
    return dict(visual_type=kind, name=name, title=title, x=x, y=y, width=w, height=h, fields=fields)


LEFT_B, RIGHT_B = (M, ROW_B[0], HALF, ROW_B[1]), (M + HALF + G, ROW_B[0], HALF, ROW_B[1])
LEFT_C, RIGHT_C = (M, ROW_C[0], HALF, ROW_C[1]), (M + HALF + G, ROW_C[0], HALF, ROW_C[1])
FULL_C = (M, ROW_C[0], W, ROW_C[1])

PAGES = {
    "Overview": ("Sales and Margin Overview", card_row([
        ("kNetRevenue", "Net Revenue"),
        ("kRevenueYoY", "Net Revenue YoY %"),
        ("kRevenueAttainment", "Net Revenue Attainment %"),
        ("kGrossProfit", "Gross Profit"),
        ("kProfitAttainment", "Gross Profit Attainment %"),
        ("kGrossMargin", "Gross Margin %"),
    ]) + [
        visual("lineClusteredColumnComboChart", "revenueTrend", "Net revenue vs budget by month", LEFT_B,
               {"Category": "Date.Month", "Y": "_Measures.Net Revenue", "Y2": "_Measures.Budget Net Revenue"}),
        visual("lineChart", "marginTrend", "Gross margin % vs budget and prior year by month", RIGHT_B,
               {"Category": "Date.Month", "Y": ["_Measures.Gross Margin %", "_Measures.Budget Gross Margin %", "_Measures.Gross Margin % PY"]}),
        visual("pivotTable", "channelSummary", "Channels: revenue, profit and budget attainment", LEFT_C,
               {"Rows": "Channel.Channel", "Values": ["_Measures.Net Revenue", "_Measures.Net Revenue Attainment %",
                                                      "_Measures.Gross Profit", "_Measures.Gross Profit Attainment %"]}),
        visual("clusteredBarChart", "categoryProfit", "Gross profit vs budget by category", RIGHT_C,
               {"Category": "Category.Category", "Y": ["_Measures.Gross Profit", "_Measures.Budget Gross Profit"]}),
    ]),
    "Budget": ("Actual versus Budget", card_row([
        ("kRevenueGap", "Net Revenue vs Budget"),
        ("kRevenueAttainment", "Net Revenue Attainment %"),
        ("kProfitGap", "Gross Profit vs Budget"),
        ("kProfitAttainment", "Gross Profit Attainment %"),
    ]) + [
        visual("clusteredBarChart", "regionGap", "Gross profit vs budget by region", LEFT_B,
               {"Category": "Region.Region", "Y": "_Measures.Gross Profit vs Budget"}),
        visual("clusteredBarChart", "categoryGap", "Gross profit vs budget by category", RIGHT_B,
               {"Category": "Category.Category", "Y": "_Measures.Gross Profit vs Budget"}),
        visual("pivotTable", "budgetMatrix", "Budget attainment by channel and region", FULL_C,
               {"Rows": ["Channel.Channel", "Region.Region"],
                "Values": ["_Measures.Net Revenue", "_Measures.Budget Net Revenue", "_Measures.Net Revenue Attainment %", "_Measures.Gross Profit", "_Measures.Budget Gross Profit",
                           "_Measures.Gross Profit vs Budget", "_Measures.Gross Profit Attainment %"]}),
    ]),
    "Margin Drivers": ("Margin, Discounts and Returns", card_row([
        ("kMargin", "Gross Margin %"),
        ("kMarginPp", "Gross Margin YoY (pp)"),
        ("kDiscountRate", "Discount Rate %"),
        ("kReturnRate", "Return Rate %"),
    ]) + [
        visual("lineChart", "marginByChannel", "Gross margin % by channel and month", LEFT_B,
               {"Category": "Date.Month", "Y": "_Measures.Gross Margin %", "Series": "Channel.Channel"}),
        visual("clusteredColumnChart", "marginByCategory", "Gross margin % by category, this year and prior year", RIGHT_B,
               {"Category": "Category.Category", "Y": ["_Measures.Gross Margin %", "_Measures.Gross Margin % PY"]}),
        visual("pivotTable", "discountMatrix", "Discount rate % by region and channel", LEFT_C,
               {"Rows": "Region.Region", "Columns": "Channel.Channel", "Values": "_Measures.Discount Rate %"}),
        visual("clusteredBarChart", "returnsByCategory", "Return rate % by category (attributed to the original sale)", RIGHT_C,
               {"Category": "Category.Category", "Y": "_Measures.Return Rate %", "Tooltips": "_Measures.Returns"}),
    ]),
    "Products and Customers": ("Profit by Product and Customer", [
        visual("scatterChart", "productScatter", "Products: net revenue and gross margin %", (M, ROW_A[0], HALF, ROW_B[0] + ROW_B[1] - ROW_A[0]),
               {"Category": "Product.Product", "X": "_Measures.Net Revenue", "Y": "_Measures.Gross Margin %", "Series": "Category.Category"}),
        visual("tableEx", "topCustomers", "Top 15 customers by gross profit", (M + HALF + G, ROW_A[0], HALF, ROW_B[0] + ROW_B[1] - ROW_A[0]),
               # the id keeps customers with the same name apart (names repeat across cities)
               {"Values": ["Customer.Customer Id", "Customer.Customer", "Customer.Segment", "_Measures.Net Revenue",
                           "_Measures.Gross Profit", "_Measures.Gross Margin %"]}),
        visual("tableEx", "products", "Products by gross profit", FULL_C,
               {"Values": ["Product.Product", "Category.Category", "_Measures.Units Sold", "_Measures.Net Revenue", "_Measures.Gross Profit",
                           "_Measures.Gross Margin %", "_Measures.Discount Rate %", "_Measures.Return Rate %"]}),
    ]),
    "Orders and Data Quality": ("Orders, Cancellations and Data Quality", card_row([
        ("kOrders", "Orders"),
        ("kCancellation", "Cancellation Rate %"),
        ("kOpenOrders", "Open Orders"),
        ("kFailedChecks", "Failed Checks"),
        ("kBudgetDifference", "Budget Workbook Difference"),
    ]) + [
        visual("clusteredBarChart", "aovByChannel", "Average order value by channel", LEFT_B,
               {"Category": "Channel.Channel", "Y": "_Measures.Average Order Value", "Tooltips": "_Measures.Invoiced Orders"}),
        visual("clusteredBarChart", "cancellationByChannel", "Cancellation rate % by channel", RIGHT_B,
               {"Category": "Channel.Channel", "Y": "_Measures.Cancellation Rate %", "Tooltips": "_Measures.Cancelled Order Value"}),
        visual("tableEx", "dqChecks", "Data quality checks (dq.usp_RunChecks)", FULL_C,
               {"Values": ["Data Quality Check.Check Code", "Data Quality Check.Check", "Data Quality Check.Affected Rows",
                           "Data Quality Check.Unhandled Rows", "Data Quality Check.Result", "Data Quality Check.Handling"]}),
    ]),
}


def header(page, title):
    for v in visuals_on(page):   # new pages come with a default title textbox
        if v["type"] == "textbox":
            pbir("rm", vpath(page, v["id"]), "-f")
    pbir("add", "title", f"{R}/{page}.Page", title, "--width", "560")
    textbox = [v["id"] for v in visuals_on(page) if v["type"] == "textbox"][0]
    pbir("visuals", "position", vpath(page, textbox), "--x", str(M), "--y", "0", "--width", "560", "--height", "62")
    pbir("visuals", "padding", vpath(page, textbox), "--top", "0", "--bottom", "0", "--left", "0", "--right", "0")
    return [
        dict(visual_type="card", name="filterContext", x=600, y=8, width=W + M - 600, height=24, fields={"Values": "_Measures.Filter Context"}),
        dict(visual_type="card", name="dataStatus", x=600, y=34, width=W + M - 600, height=24, fields={"Values": "_Measures.Data Status"}),
        dict(visual_type="pageNavigator", name="nav", x=M, y=62, width=W, height=46),
    ]


def visuals_on(page):
    return json.loads(subprocess.run([PBIR, "-q", "--output-format", "json", "ls", f"{R}/{page}.Page"], cwd=ROOT,
                                     capture_output=True, text=True, encoding="utf-8").stdout)["visuals"]


def vpath(page, name):
    return f"{R}/{page}.Page/{name}.Visual"


def main():
    shutil.rmtree(ROOT / R, ignore_errors=True)
    (ROOT / "VelmoraSales.pbip").unlink(missing_ok=True)
    pbir("new", "report", R, "--thick", "--no-title")
    pbir("report", "rebind", R, "--local", "../VelmoraSales.SemanticModel")
    pbir("pages", "rename", f"{R}/Page 1.Page", "--to", "Overview", "-f")
    for prop, value in [("card.*.labels.fontSize", "24"), ("card.*.categoryLabels.fontSize", "10"),
                        ("lineChart.*.lineStyles.areaShow", "false"),
                        ("tableEx.*.values.fontSize", "10"), ("tableEx.*.columnHeaders.fontSize", "10"), ("tableEx.*.total.fontSize", "10"),
                        ("pivotTable.*.values.fontSize", "10"), ("pivotTable.*.columnHeaders.fontSize", "10"),
                        ("pivotTable.*.rowHeaders.fontSize", "10"), ("pivotTable.*.total.fontSize", "10")]:
        pbir("theme", "set-formatting", R, prop, "--value", value)
    for page in list(PAGES)[1:]:
        pbir("add", "page", f"{R}/{page}.Page", "-n", page)

    for page, (title, visuals) in PAGES.items():
        spec = Path(tempfile.gettempdir()) / f"velmora_{page.replace(' ', '_')}.json"
        spec.write_text(json.dumps(header(page, title) + visuals), encoding="utf-8")
        pbir("add", "visual", f"{R}/{page}.Page", "--from-json", str(spec))

    for page in PAGES:   # header text lines: small value, no category label, no padding
        for name in ("filterContext", "dataStatus"):
            pbir("set", f"{vpath(page, name)}.labels.fontSize", "--value", "11")
            pbir("set", f"{vpath(page, name)}.categoryLabels.show", "--value", "false")
            pbir("visuals", "padding", vpath(page, name), "--top", "0", "--bottom", "0", "--left", "4", "--right", "4")
    pbir("set", f"{vpath('Orders and Data Quality', 'kOrders')}.labels.labelDisplayUnits", "--value", "1")
    # shorter headers so the matrices fit; the model measures keep their full names
    pbir("fields", "rename", R, "_Measures.Net Revenue Attainment %", "Revenue Attainment %")
    pbir("fields", "rename", R, "_Measures.Gross Profit Attainment %", "Profit Attainment %")
    for name in ("regionGap", "categoryGap"):   # largest shortfall first
        pbir("visuals", "sort", vpath("Budget", name), "-f", "_Measures.Gross Profit vs Budget", "-d", "Ascending")
    for page, name in [("Overview", "revenueTrend"), ("Overview", "marginTrend"), ("Margin Drivers", "marginByChannel")]:
        pbir("visuals", "sort", vpath(page, name), "-f", "Date.Month", "-d", "Ascending")

    pbir("add", "filter", "Customer", "Customer Id", "-v", vpath("Products and Customers", "topCustomers"), "--type", "TopN",
         "--n", "15", "--by-table", "_Measures", "--by-field", "Gross Profit")
    for page, name, field in [("Products and Customers", "topCustomers", "_Measures.Gross Profit"),
                              ("Products and Customers", "products", "_Measures.Gross Profit"),
                              ("Overview", "categoryProfit", "_Measures.Gross Profit"),
                              ("Margin Drivers", "marginByCategory", "_Measures.Gross Margin %"),
                              ("Margin Drivers", "returnsByCategory", "_Measures.Return Rate %")]:
        pbir("visuals", "sort", vpath(page, name), "-f", field, "-d", "Descending")

    # report-level filters: the same selection on every page; the year opens on the latest full year
    # (an Advanced filter, because a categorical filter is written with a text literal that never matches the integer year)
    pbir("add", "filter", "Date", "Year", "-r", R, "--type", "Advanced", "--operator", "Is", "--values", "2025")
    for table, field in [("Channel", "Channel"), ("Region", "Region"), ("Category", "Category")]:
        pbir("add", "filter", table, field, "-r", R)
    pbir("pages", "active-page", R, "Overview")
    print(pbir("validate", R).strip().splitlines()[-1])


if __name__ == "__main__":
    main()
