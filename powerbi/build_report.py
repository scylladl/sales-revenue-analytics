"""
Builds a VelmoraSales report from scratch through the pbir CLI, in one of two designs on the same semantic model:
  light  powerbi/VelmoraSales.Report       (the main report)
  dark   powerbi/VelmoraSales-Dark.Report

Every page, visual, binding and filter is created with pbir commands, so the report can be rebuilt and reviewed as
code. The script recreates the report folder: manual edits made in Power BI Desktop are lost unless they are
copied here first. Close the report in Power BI Desktop before running it.

Both designs share the layout: a navigation rail on the left with the brand and one button per page, actual values
in the first colour (caramel, copper in the dark design) and comparison series (budget, prior year) in blue.
"Velmora Roast" is a cream canvas with an espresso rail; "Velmora Dark Roast" a dark coffee canvas with copper
accents. Each categorical palette passes the colour-vision checks of the dataviz validator (lightness band,
chroma, CVD and normal-vision separation, contrast) on its own visual background.

Usage: python powerbi/build_report.py [--design light|dark]
"""
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PBIR = shutil.which("pbir") or str(Path.home() / "AppData/Roaming/Python/Python313/Scripts/pbir.exe")

# 1280 x 720 canvas: a 160 px rail on the left, then 24 px margins and 16 px gaps
RAIL, M, G = 160, 24, 16
X0 = RAIL + M
W = 1280 - X0 - M
HALF = (W - G) // 2
ROW_A, ROW_B, ROW_C = (76, 92), (184, 248), (448, 248)

DESIGNS = {
    "light": dict(
        report="VelmoraSales.Report", theme_name="Velmora Roast", page="#F7F2EA", wallpaper="#EFE6DA", border="#E6DACB",
        rail="#3B2A20", brand="#F7F2EA", brand_note="#CDBBA7", nav_text="#E9DCCB", nav_active_fill="#B4612A",
        nav_active_text="#FFFFFF", header_text="#3B2A20", header_note="#7A6A5E",
        theme=dict(data=["#B4612A", "#2F6FB0", "#3A9150", "#A0507E", "#8F7420", "#6A4FA0"], background="#FFFDF9",
                   background_light="#F7F2EA", foreground="#3B2A20", secondary="#7A6A5E", table_accent="#B4612A",
                   good="#3A9150", bad="#B03A2E", neutral="#8C8279", minimum="#F3E6D8", maximum="#B4612A"),
        fonts={"title": ("Segoe UI Semibold", 12, "#3B2A20"), "header": ("Segoe UI Semibold", 11, "#3B2A20"),
               "label": ("Segoe UI", 10, "#5A4A3F"), "callout": ("Segoe UI Semibold", 24, "#3B2A20"),
               "dataTitle": ("Segoe UI", 10, "#7A6A5E"), "smallLabel": ("Segoe UI", 9, "#5A4A3F")}),
    "dark": dict(
        report="VelmoraSales-Dark.Report", theme_name="Velmora Dark Roast", page="#1C1512", wallpaper="#140F0C",
        border="#3A2C24", rail="#120D0A", brand="#F1E7DA", brand_note="#A89786", nav_text="#D9CBBB",
        nav_active_fill="#CC7838", nav_active_text="#1C1512", header_text="#F1E7DA", header_note="#B5A493",
        theme=dict(data=["#CC7838", "#3F8FDB", "#45A85A", "#C65E97", "#B08A22", "#8A73D6"], background="#271D18",
                   background_light="#2F241E", foreground="#F1E7DA", secondary="#B5A493", table_accent="#CC7838",
                   good="#45A85A", bad="#E0705A", neutral="#9C8F82", minimum="#3A2C24", maximum="#CC7838"),
        fonts={"title": ("Segoe UI Semibold", 12, "#F1E7DA"), "header": ("Segoe UI Semibold", 11, "#F1E7DA"),
               "label": ("Segoe UI", 10, "#D9CBBB"), "callout": ("Segoe UI Semibold", 24, "#F6EEE4"),
               "dataTitle": ("Segoe UI", 10, "#B5A493"), "smallLabel": ("Segoe UI", 9, "#D9CBBB")}),
}
D = DESIGNS["light"]
R = D["report"]
NAV_LABELS = {"Products and Customers": "Products", "Orders and Data Quality": "Orders & Quality"}
# rail shape and buttons: no container chrome (the theme gives every visual a title, divider and rounded border).
# Fill and text stay per visual: buttons and shapes keep them per state, and theme defaults do not reach them.
RAIL_THEME = [(f"{kind}.*.{prop}", value) for kind in ("actionButton", "shape") for prop, value in [
    ("title.show", "false"), ("divider.show", "false"), ("border.show", "false"), ("background.show", "false"),
    ("padding.top", "0"), ("padding.bottom", "0"), ("padding.left", "0"), ("padding.right", "0")]]


def base_colors(theme, line, callout):
    """Colours the sqlbi base theme fixes as literals (cards, tables, axes, legends), set from the design instead."""
    text, muted, surface, alt = theme["foreground"], theme["secondary"], theme["background"], theme["background_light"]
    props = [("card.*.labels.color", callout), ("card.*.categoryLabels.color", muted),
             ("*.*.categoryAxis.labelColor", muted), ("*.*.valueAxis.labelColor", muted),
             ("*.*.valueAxis.gridlineColor", line), ("*.*.categoryAxis.gridlineColor", line),
             ("*.*.legend.labelColor", text), ("*.*.labels.color", text), ("*.*.divider.color", line)]
    for table in ("tableEx", "pivotTable"):
        props += [(f"{table}.*.{prop}", value) for prop, value in [
            ("columnHeaders.backColor", alt), ("columnHeaders.fontColor", text), ("columnHeaders.outlineColor", line),
            ("values.backColorPrimary", surface), ("values.backColorSecondary", alt),
            ("values.fontColorPrimary", text), ("values.fontColorSecondary", text), ("values.outlineColor", line),
            ("total.backColor", alt), ("total.fontColor", text), ("total.outlineColor", line),
            ("grid.gridHorizontalColor", line), ("grid.gridVerticalColor", line), ("grid.outlineColor", line)]]
    props += [(f"pivotTable.*.rowHeaders.{prop}", value) for prop, value in
              [("backColor", alt), ("fontColor", text), ("outlineColor", line)]]
    props += [(f"pivotTable.*.{totals}.{prop}", value) for totals in ("subTotals", "rowTotal", "columnTotal")
              for prop, value in [("backColor", alt), ("fontColor", text)]]
    return props


def pbir(*args):
    result = subprocess.run([PBIR, "-q", *args], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if result.returncode != 0:
        sys.exit(f"pbir {' '.join(args)} failed:\n{(result.stdout + result.stderr)[-2000:]}")
    return result.stdout


def columns(count):
    width = (W - (count - 1) * G) // count
    return [(X0 + i * (width + G), width) for i in range(count)]


def card_row(cards):
    """cards: (visual name, measure), laid out in equal columns along the top row"""
    return [dict(visual_type="card", name=name, x=x, y=ROW_A[0], width=w, height=ROW_A[1], fields={"Values": f"_Measures.{measure}"})
            for (name, measure), (x, w) in zip(cards, columns(len(cards)))]


def visual(kind, name, title, slot, fields):
    x, y, w, h = slot
    return dict(visual_type=kind, name=name, title=title, x=x, y=y, width=w, height=h, fields=fields)


LEFT_B, RIGHT_B = (X0, ROW_B[0], HALF, ROW_B[1]), (X0 + HALF + G, ROW_B[0], HALF, ROW_B[1])
LEFT_C, RIGHT_C = (X0, ROW_C[0], HALF, ROW_C[1]), (X0 + HALF + G, ROW_C[0], HALF, ROW_C[1])
FULL_C = (X0, ROW_C[0], W, ROW_C[1])
TALL = ROW_B[0] + ROW_B[1] - ROW_A[0]

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
        visual("pivotTable", "channelSummary", "Channels: revenue and budget attainment", LEFT_C,
               {"Rows": "Channel.Channel", "Values": ["_Measures.Net Revenue", "_Measures.Net Revenue Attainment %",
                                                      "_Measures.Gross Profit Attainment %"]}),
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
    # change requests CR-01 to CR-03 (docs/02-change-log.md)
    "Profit Levers": ("Profit Levers", card_row([
        ("kAbovePolicy", "Discount Above Policy"),
        ("kLinesAbovePolicy", "Lines Above Policy %"),
        ("kPromotionDay", "Gross Profit per Promotion Day"),
        ("kOrdinaryDay", "Gross Profit per Ordinary Day"),
        ("kPromotionRatio", "Promotion Profit Ratio %"),
    ]) + [
        visual("waterfallChart", "marginBridge", "Change of gross margin % from the previous year, by cause (pp)", LEFT_B,
               {"Category": "Margin Bridge Step.Step", "Y": "_Measures.Margin Bridge (pp)"}),
        visual("clusteredBarChart", "policyByRegion", "Discount above the contract policy by region", RIGHT_B,
               {"Category": "Region.Region", "Y": "_Measures.Discount Above Policy", "Tooltips": "_Measures.Lines Above Policy %"}),
        visual("pivotTable", "promotionDays", "Retail capsules: promotion days vs other days of those months", LEFT_C,
               {"Rows": "Sales.Promotion Period", "Values": ["_Measures.Gross Profit per Order Day", "_Measures.Units per Order Day",
                                                             "_Measures.Gross Margin %"]}),
        visual("pivotTable", "policyBySegment", "HoReCa: discount above policy by region and tier", RIGHT_C,
               {"Rows": "Region.Region", "Columns": "Customer.Segment", "Values": "_Measures.Discount Above Policy"}),
    ]),
    "Products and Customers": ("Profit by Product and Customer", [
        visual("scatterChart", "productScatter", "Products: net revenue and gross margin %", (X0, ROW_A[0], HALF, TALL),
               {"Category": "Product.Product", "X": "_Measures.Net Revenue", "Y": "_Measures.Gross Margin %", "Series": "Category.Category"}),
        visual("tableEx", "topCustomers", "Top 15 customers by gross profit", (X0 + HALF + G, ROW_A[0], HALF, TALL),
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
    pbir("visuals", "position", vpath(page, textbox), "--x", str(X0), "--y", "0", "--width", "560", "--height", "62")
    pbir("visuals", "padding", vpath(page, textbox), "--top", "0", "--bottom", "0", "--left", "0", "--right", "0")
    side = X0 + 560 + G
    rail = [dict(visual_type="shape", name="rail", x=0, y=0, width=RAIL, height=720),
            dict(visual_type="actionButton", name="brand", x=12, y=16, width=RAIL - 24, height=30),
            dict(visual_type="actionButton", name="brandNote", x=12, y=46, width=RAIL - 24, height=20)]
    rail += [dict(visual_type="actionButton", name=f"nav{i}", x=12, y=96 + i * 44, width=RAIL - 24, height=36)
             for i in range(len(PAGES))]
    return rail + [
        dict(visual_type="card", name="filterContext", x=side, y=14, width=1280 - M - side, height=22, fields={"Values": "_Measures.Filter Context"}),
        dict(visual_type="card", name="dataStatus", x=side, y=38, width=1280 - M - side, height=22, fields={"Values": "_Measures.Data Status"}),
    ]


def button(path, text, size, color, fill, bold=False):
    for prop, value in [("text.show", "true"), ("text.text", text), ("text.fontSize", str(size)), ("text.fontColor", color),
                        ("text.bold", "true" if bold else "false"), ("text.horizontalAlignment", "left"),
                        ("text.leftMargin", "10"), ("icon.show", "false"), ("outline.show", "false"),
                        ("fill.show", "true"), ("fill.fillColor", fill), ("fill.transparency", "0")]:
        pbir("set", f"{path}.{prop}", "--value", value)


def style_page(page, page_ids):
    rail = vpath(page, "rail")
    for prop, value in [("fill.show", "true"), ("fill.fillColor", D["rail"]), ("fill.transparency", "0"), ("outline.show", "false")]:
        pbir("set", f"{rail}.{prop}", "--value", value)
    pbir("visuals", "z-order", rail, "--back")
    button(vpath(page, "brand"), "Velmora", 16, D["brand"], D["rail"], bold=True)
    button(vpath(page, "brandNote"), "Coffee Roasters", 9, D["brand_note"], D["rail"])
    for i, target in enumerate(PAGES):
        path = vpath(page, f"nav{i}")
        active = target == page
        button(path, NAV_LABELS.get(target, target), 10, D["nav_active_text"] if active else D["nav_text"],
               D["nav_active_fill"] if active else D["rail"], bold=active)
        # Power BI navigates by page id, not by display name
        pbir("visuals", "action", path, "--type", "PageNavigation", "--target", page_ids[target])
        pbir("visuals", "general", path, "--altText", f"Go to the {target} page")
    for name in ("filterContext", "dataStatus"):   # header text lines: small value, no label, no box
        pbir("set", f"{vpath(page, name)}.labels.fontSize", "--value", "10" if name == "dataStatus" else "11")
        pbir("set", f"{vpath(page, name)}.labels.color", "--value", D["header_note"] if name == "dataStatus" else D["header_text"])
        pbir("set", f"{vpath(page, name)}.categoryLabels.show", "--value", "false")
        pbir("visuals", "padding", vpath(page, name), "--top", "0", "--bottom", "0", "--left", "4", "--right", "4")
        pbir("visuals", "background", vpath(page, name), "--transparency", "100")
        pbir("visuals", "border", vpath(page, name), "--no-show")
    pbir("pages", "background", f"{R}/{page}.Page", "--color", D["page"], "--transparency", "0")
    pbir("pages", "wallpaper", f"{R}/{page}.Page", "--color", D["wallpaper"], "--transparency", "0")


def visuals_on(page):
    return json.loads(subprocess.run([PBIR, "-q", "--output-format", "json", "ls", f"{R}/{page}.Page"], cwd=ROOT,
                                     capture_output=True, text=True, encoding="utf-8").stdout)["visuals"]


def vpath(page, name):
    return f"{R}/{page}.Page/{name}.Visual"


def main():
    global D, R
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("--design", choices=list(DESIGNS), default="light")
    D = DESIGNS[parser.parse_args().design]
    R = D["report"]
    THEME, FONTS = D["theme"], D["fonts"]

    shutil.rmtree(ROOT / R, ignore_errors=True)
    (ROOT / R.replace(".Report", ".pbip")).unlink(missing_ok=True)
    pbir("new", "report", R, "--thick", "--no-title")
    pbir("report", "rebind", R, "--local", "../VelmoraSales.SemanticModel")
    pbir("pages", "rename", f"{R}/Page 1.Page", "--to", "Overview", "-f")
    pbir("theme", "set-colors", R, "--data-colors", json.dumps(THEME["data"]), "--background", THEME["background"],
         "--background-light", THEME["background_light"], "--foreground", THEME["foreground"],
         "--foreground-neutral-secondary", THEME["secondary"], "--table-accent", THEME["table_accent"], "--good", THEME["good"],
         "--bad", THEME["bad"], "--neutral", THEME["neutral"], "--minimum", THEME["minimum"], "--maximum", THEME["maximum"])
    pbir("theme", "rename", R, D["theme_name"])
    for text_class, (face, size, color) in FONTS.items():
        pbir("theme", "set-fonts", R, text_class, "--font-face", face, "--font-size", str(size), "--color", color)
    # the sqlbi base theme fixes white visual backgrounds and a grey canvas; both follow the design instead
    pbir("theme", "background", R, "--clear")
    for prop, value in [("*.*.background.color", THEME["background"]), ("*.*.background.transparency", "0"),
                        ("page.*.background.color", D["page"]), ("page.*.background.transparency", "0"),
                        ("*.*.dropShadow.show", "false"), ("*.*.border.show", "true"), ("*.*.border.color", D["border"]),
                        ("*.*.border.radius", "8"),
                        ("*.*.dataPoint.fillTransparency", "0"), ("*.*.dataPoint.borderShow", "false"),   # solid marks
                        ("card.*.labels.fontSize", "24"), ("card.*.categoryLabels.fontSize", "10"),
                        ("*.*.lineStyles.areaShow", "false"),
                        ("tableEx.*.values.fontSize", "10"), ("tableEx.*.columnHeaders.fontSize", "10"), ("tableEx.*.total.fontSize", "10"),
                        ("pivotTable.*.values.fontSize", "10"), ("pivotTable.*.columnHeaders.fontSize", "10"),
                        ("pivotTable.*.rowHeaders.fontSize", "10"), ("pivotTable.*.total.fontSize", "10")]:
        pbir("theme", "set-formatting", R, prop, "--value", value)
    for prop, value in RAIL_THEME + base_colors(THEME, D["border"], FONTS["callout"][2]):
        pbir("theme", "set-formatting", R, prop, "--value", value)
    for text_class in ("largeTitle", "boldLabel", "largeLabel", "largeLightLabel", "lightLabel", "semiboldLabel",
                       "smallDataLabel", "smallLightLabel"):
        pbir("theme", "set-fonts", R, text_class, "--color", THEME["foreground"])
    for page in list(PAGES)[1:]:
        pbir("add", "page", f"{R}/{page}.Page", "-n", page)

    page_ids = {p["displayName"]: p["id"] for p in json.loads(pbir("--output-format", "json", "ls", R))["pages"]}
    for page, (title, visuals) in PAGES.items():
        spec = Path(tempfile.gettempdir()) / f"velmora_{page.replace(' ', '_')}.json"
        spec.write_text(json.dumps(header(page, title) + visuals), encoding="utf-8")
        pbir("add", "visual", f"{R}/{page}.Page", "--from-json", str(spec), "--force")   # buttons sit on the rail
        style_page(page, page_ids)
    pbir("set", f"{vpath('Orders and Data Quality', 'kOrders')}.labels.labelDisplayUnits", "--value", "1")
    pbir("set", f"{vpath('Orders and Data Quality', 'kOrders')}.labels.labelPrecision", "--value", "0")
    # shorter headers so the matrices fit; the model measures keep their full names
    pbir("fields", "rename", R, "_Measures.Net Revenue Attainment %", "Revenue Attainment %")
    pbir("fields", "rename", R, "_Measures.Gross Profit Attainment %", "Profit Attainment %")
    for measure, label in [("Gross Profit per Promotion Day", "Profit per Promotion Day"),
                           ("Gross Profit per Ordinary Day", "Profit per Ordinary Day"),
                           ("Gross Profit per Order Day", "Profit per Day"), ("Units per Order Day", "Units per Day")]:
        pbir("fields", "rename", R, f"_Measures.{measure}", label)
    for name in ("regionGap", "categoryGap"):   # largest shortfall first
        pbir("visuals", "sort", vpath("Budget", name), "-f", "_Measures.Gross Profit vs Budget", "-d", "Ascending")
    for page, name in [("Overview", "revenueTrend"), ("Overview", "marginTrend"), ("Margin Drivers", "marginByChannel")]:
        pbir("visuals", "sort", vpath(page, name), "-f", "Date.Month", "-d", "Ascending")
    pbir("visuals", "sort", vpath("Profit Levers", "marginBridge"), "-f", "Margin Bridge Step.Step", "-d", "Ascending")
    pbir("visuals", "sort", vpath("Profit Levers", "policyByRegion"), "-f", "_Measures.Discount Above Policy", "-d", "Descending")
    pbir("add", "filter", "Channel", "Channel", "-v", vpath("Profit Levers", "policyBySegment"), "--values", "HoReCa")
    pbir("add", "filter", "Sales", "Promotion Period", "-v", vpath("Profit Levers", "promotionDays"),
         "--values", "Promotion", "--values", "Rest of month")   # promotion months only

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
