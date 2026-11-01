"""
Synthetic source data for Velmora Coffee Roasters (fictional).

Plays the role of the company's ERP: it writes the CSV exports that database/load_source_data.py loads into the
src schema, and the budget workbook that finance sends every year (read by Power Query). Everything is simulated;
the same seed always produces the same data.

Patterns the data follows, so the analysis has something to find:
- three channels with different economics: HoReCa (contract discounts by tier), Retail (store orders, funded
  promotions, returns of damaged stock) and E-commerce (campaigns, equipment returns);
- green coffee cost rises through 2024 and 2025, while list prices rise later and by less;
- e-commerce grows fastest and sells more equipment every year;
- seasonality: Christmas peak, August dip in HoReCa, Black Friday in e-commerce.

It also writes the defects real exports have (duplicate customers, a missing monthly cost, returns above the
invoiced quantity, invoices dated before their order, customers without region, a messy budget workbook).
data/generated/defects.json lists them for the private test inventory.

Usage: python generator/generate_data.py [--seed 7] [--out data/generated]
Needs openpyxl (requirements.txt) for the budget workbook.
"""
import argparse
import csv
import json
import random
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

from openpyxl import Workbook

START, END = date(2023, 1, 1), date(2025, 12, 31)
EXTRACTED_AT = datetime(2026, 1, 1, 2, 0)

REGIONS = {  # code: (weight, cities)
    "VAL": (0.22, ["Valencia", "Alicante", "Castellón", "Murcia", "Elche"]),
    "CAT": (0.20, ["Barcelona", "Tarragona", "Girona", "Palma"]),
    "MAD": (0.22, ["Madrid", "Toledo", "Guadalajara", "Alcalá de Henares"]),
    "AND": (0.16, ["Sevilla", "Málaga", "Granada", "Córdoba", "Cádiz"]),
    "NOR": (0.12, ["Bilbao", "San Sebastián", "Pamplona", "Santander", "Oviedo"]),
    "NWE": (0.08, ["A Coruña", "Vigo", "Valladolid", "León"]),
}
OVER_DISCOUNT_REGION = "AND"  # HoReCa reps there give more than the tier policy

TIERS = {"Gold": (0.15, 12.0), "Silver": (0.35, 8.0), "Bronze": (0.50, 4.0)}  # share, contract discount %
CHAIN_NAMES = ["Mercaval", "SuperNorte", "HiperSol", "Ahorramas Local", "Frescor", "La Despensa", "MercaBarrio",
               "Cesta Viva", "Supermercados Brisa", "DiaFresco", "Hiper Levante", "Mercado Central"]

# category: (VAT %, food, cost share of price in 2023, coffee share of cost)
CATEGORIES = {"BEANS": (10, True, 0.30, 0.72), "GROUND": (10, True, 0.31, 0.70), "CAPS": (10, True, 0.34, 0.45),
              "GIFT": (10, True, 0.42, 0.40), "ACCS": (21, False, 0.46, 0.0), "EQUIP": (21, False, 0.64, 0.0)}
CHANNEL_PRICE = {"ECOM": 1.0, "HORECA": 0.70, "RETAIL": 0.62}  # list price relative to the e-commerce price

BLENDS = ["Signature Espresso", "Bairro Blend", "Mañana Blend", "Decaf Swiss Water", "Colombia Huila",
          "Ethiopia Yirgacheffe", "Brazil Cerrado", "Guatemala Antigua", "Kenya AA", "Organic Peru"]
CAPSULES = ["Ristretto", "Lungo", "Espresso Forte", "Decaf", "Caramel", "Vanilla", "Colombia", "Ethiopia",
            "Organic", "Intenso"]
ACCESSORIES = [("Paper filters 100", 6), ("Pour-over dripper", 24), ("Glass carafe 600 ml", 29),
               ("Hand grinder", 59), ("Digital scale", 39), ("Milk jug 600 ml", 22), ("Espresso tamper", 34),
               ("Knock box", 27), ("Travel mug", 19), ("Cold brew bottle", 26), ("Cleaning tablets", 12),
               ("Descaler", 11), ("Gooseneck kettle", 79), ("Cupping spoon set", 16), ("Barista cloths", 9),
               ("French press 1 l", 32), ("Aeropress-style brewer", 36), ("Storage canister", 21),
               ("Dosing cup", 14), ("Grinder brush", 8)]
EQUIPMENT = [("Home burr grinder", 149, False), ("Precision grinder", 329, False), ("Espresso machine Casa", 449,
             False), ("Espresso machine Duo", 899, False), ("Bean-to-cup machine", 1190, False),
             ("Filter brewer", 189, False), ("Milk frother", 119, False), ("Pro on-demand grinder", 1290, True),
             ("Pro espresso machine 2G", 3990, True), ("Water filter kit", 159, True)]


def months():
    d = START
    while d <= END:
        yield d.year * 100 + d.month
        d = (d.replace(day=28) + timedelta(days=4)).replace(day=1)


def green_index(month: int) -> float:
    """Green coffee cost index: flat in 2023, rising through 2024, peaking in spring 2025."""
    y, m = divmod(month, 100)
    t = (y - 2023) * 12 + m - 1  # 0..35
    if t < 12:
        return 1.0 + 0.0035 * t
    if t < 27:
        return 1.04 + 0.36 * (t - 12) / 15
    return 1.40 - 0.008 * (t - 27)


def make_products(rng):
    products = []

    def add(code, cat, name, size, price, channels, launch=START, coffee=None):
        vat, food, cost_share, coffee_share = CATEGORIES[cat]
        products.append({"ProductId": code, "ProductName": name, "CategoryCode": cat, "PackSize": size,
                         "LaunchDate": launch, "VatRate": vat, "IsFood": food, "price": price,
                         "base_cost": price * cost_share * rng.uniform(0.92, 1.08),
                         "coffee_share": coffee_share if coffee is None else coffee, "channels": channels})

    for i, blend in enumerate(BLENDS, 1):
        add(f"VEL-BN-{i:02d}2", "BEANS", f"{blend} beans 250 g", "250 g", rng.uniform(8.5, 14), ["ECOM", "RETAIL"])
        add(f"VEL-BN-{i:02d}K", "BEANS", f"{blend} beans 1 kg", "1 kg", rng.uniform(26, 44), ["ECOM", "HORECA"])
    for i, blend in enumerate(BLENDS[:8], 1):
        price = rng.uniform(6, 10)
        add(f"VEL-GR-{i:02d}2", "GROUND", f"{blend} ground 250 g", "250 g", price, ["ECOM", "RETAIL"])
        add(f"VEL-GR-{i:02d}5", "GROUND", f"{blend} ground 500 g", "500 g", price * 1.85, ["RETAIL"])
    for i, flavour in enumerate(CAPSULES, 1):
        price = rng.uniform(3.6, 4.6)
        add(f"VEL-CP-{i:02d}1", "CAPS", f"{flavour} capsules x10", "10 caps", price, ["ECOM", "RETAIL"])
        add(f"VEL-CP-{i:02d}3", "CAPS", f"{flavour} capsules x30", "30 caps", price * 2.6, ["ECOM", "RETAIL"])
    for i, name in enumerate(["Christmas Discovery", "Origins Trio", "Espresso Lover", "Capsule Advent",
                              "Barista Starter", "Holiday Mug Set", "Single Origin Tasting", "Corporate Gift"], 1):
        add(f"VEL-GF-{i:02d}", "GIFT", f"{name} pack", "pack", rng.uniform(24, 62), ["ECOM", "RETAIL"],
            launch=date(2023, 10, 1) if i > 5 else START)
    for i, (name, price) in enumerate(ACCESSORIES, 1):
        add(f"VEL-AC-{i:02d}", "ACCS", name, "unit", price, ["ECOM", "HORECA"] if i in (6, 7, 8, 11, 12, 15)
            else ["ECOM"])
    for i, (name, price, pro) in enumerate(EQUIPMENT, 1):
        add(f"VEL-EQ-{i:02d}", "EQUIP", name, "unit", price, ["HORECA"] if pro else ["ECOM"],
            launch=date(2024, 3, 1) if name == "Bean-to-cup machine" else START)
    return products


def list_price(product, channel, day):
    price = product["price"] * CHANNEL_PRICE[channel]
    increase_from = date(2025, 7, 1) if channel == "RETAIL" else date(2025, 2, 1)
    if product["CategoryCode"] in ("BEANS", "GROUND", "CAPS", "GIFT") and day >= increase_from:
        price *= 1.07
    return round(price, 2)


def unique_name(rng, used, city, draw):
    """A business name not yet used in the city (two different businesses rarely share one there)."""
    while True:
        name = draw()
        if (name, city) not in used:
            used.add((name, city))
            return name


def make_customers(rng):
    customers = []
    used = set()
    region_codes = list(REGIONS)
    weights = [REGIONS[r][0] for r in region_codes]
    words = ["Sol", "Mar", "Plaza", "Central", "Puerto", "Jardín", "Esquina", "Lonja", "Ribera", "Alameda",
             "Mercado", "Estación", "Barrio", "Faro", "Olivo", "Naranjo", "Rambla", "Torre", "Huerta", "Brisa"]
    kinds = ["Café", "Bar", "Cafetería", "Restaurante", "Hotel", "Bistró", "Pastelería", "Coworking"]
    for i in range(1, 1501):
        region = rng.choices(region_codes, weights)[0]
        tier = rng.choices(list(TIERS), [v[0] for v in TIERS.values()])[0]
        created = date(2016, 1, 1) + timedelta(days=rng.randint(0, 3600))
        city = rng.choice(REGIONS[region][1])
        name = unique_name(rng, used, city, lambda: f"{rng.choice(kinds)} {rng.choice(words)} {rng.choice(words)}")
        customers.append({"CustomerId": f"H{i:05d}", "CustomerName": name, "ChannelCode": "HORECA", "Segment": tier,
                          "RegionCode": region, "City": city, "CreatedDate": min(created, END - timedelta(90)),
                          "churn": date(2023, 1, 1) + timedelta(days=rng.randint(0, 1095)) if rng.random() < 0.2
                          else None, "orders_month": rng.uniform(1.2, 3.2), "house": None})
    store = 0
    for chain in CHAIN_NAMES:
        for _ in range(rng.randint(18, 40)):
            store += 1
            region = rng.choices(region_codes, weights)[0]
            city = rng.choice(REGIONS[region][1])
            customers.append({"CustomerId": f"R{store:05d}", "CustomerName": f"{chain} {city} {store:03d}",
                              "ChannelCode": "RETAIL", "Segment": "Chain", "RegionCode": region, "City": city,
                              "CreatedDate": date(2014, 1, 1) + timedelta(days=rng.randint(0, 3000)), "churn": None,
                              "orders_month": rng.uniform(1.6, 2.8), "house": None})
    for _ in range(60):
        store += 1
        region = rng.choices(region_codes, weights)[0]
        city = rng.choice(REGIONS[region][1])
        name = unique_name(rng, used, city, lambda: f"Gourmet {rng.choice(words)} {city}")
        customers.append({"CustomerId": f"R{store:05d}", "CustomerName": name,
                          "ChannelCode": "RETAIL", "Segment": "Gourmet", "RegionCode": region, "City": city,
                          "CreatedDate": date(2015, 1, 1) + timedelta(days=rng.randint(0, 3000)), "churn": None,
                          "orders_month": rng.uniform(0.8, 1.6), "house": None})
    return customers


def campaign_for(day):
    """E-commerce campaign active on a day: (code, discounted categories, discount %, demand multiplier)."""
    black_friday = date(day.year, 11, 30) - timedelta(days=(date(day.year, 11, 30).weekday() - 4) % 7)
    if black_friday - timedelta(days=3) <= day <= black_friday + timedelta(days=3):
        return f"BF{day.year}", {"EQUIP", "ACCS"}, 20.0, 3.0
    if date(day.year, 12, 1) <= day <= date(day.year, 12, 22):
        return f"XMAS{day.year}", {"GIFT"}, 10.0, 1.5
    if date(day.year, 6, 15) <= day <= date(day.year, 7, 15):
        return f"SUMMER{day.year}", {"BEANS", "ACCS"}, 12.0, 1.1
    return None, set(), 0.0, 1.0


def retail_promo(day):
    """Funded retail promotion weeks on capsules (four per year)."""
    return any(date(day.year, m, 1) <= day <= date(day.year, m, 10) for m in (3, 5, 9, 11))


def season(channel, day):
    m = day.month
    if channel == "HORECA":
        return {8: 0.65, 12: 1.12, 1: 0.9}.get(m, 1.0)
    if channel == "RETAIL":
        return {12: 1.35, 11: 1.1, 8: 0.9}.get(m, 1.0)
    return {12: 1.45, 11: 1.15, 1: 0.85, 8: 0.85}.get(m, 1.0)


def simulate(rng, products, customers):
    by_channel = defaultdict(list)
    for p in products:
        for ch in p["channels"]:
            by_channel[(ch, p["CategoryCode"])].append(p)
    orders, lines = [], []
    order_no = 0
    ecom_customers, next_consumer = [], 1

    def new_order(customer_id, channel, day, campaign=None):
        nonlocal order_no
        order_no += 1
        order = {"OrderId": f"SO{order_no:07d}", "CustomerId": customer_id, "ChannelCode": channel,
                 "OrderDate": day, "CampaignCode": campaign, "lines": []}
        orders.append(order)
        return order

    def add_line(order, product, qty, discount):
        if product["LaunchDate"] > order["OrderDate"]:
            return
        order["lines"].append({"OrderId": order["OrderId"], "LineNumber": len(order["lines"]) + 1,
                               "ProductId": product["ProductId"], "Quantity": qty,
                               "UnitListPrice": list_price(product, order["ChannelCode"], order["OrderDate"]),
                               "DiscountPct": round(min(discount, 100.0), 1), "VatRate": product["VatRate"],
                               "product": product})

    horeca = [c for c in customers if c["ChannelCode"] == "HORECA"]
    retail = [c for c in customers if c["ChannelCode"] == "RETAIL"]
    for c in horeca:
        c["house"] = rng.choice(by_channel[("HORECA", "BEANS")])

    day = START
    while day <= END:
        years_in = (day - START).days / 365.0
        for c in horeca:
            if c["CreatedDate"] > day or (c["churn"] and day >= c["churn"]):
                continue
            if rng.random() >= c["orders_month"] / 30.4 * season("HORECA", day) * (1 + 0.03 * years_in):
                continue
            order = new_order(c["CustomerId"], "HORECA", day)
            tier_discount = TIERS[c["Segment"]][1]
            extra = rng.uniform(4, 9) if c["RegionCode"] == OVER_DISCOUNT_REGION and rng.random() < 0.7 else 0
            add_line(order, c["house"], rng.randint(3, 18), tier_discount + extra)
            if rng.random() < 0.45:
                add_line(order, rng.choice(by_channel[("HORECA", "BEANS")]), rng.randint(1, 6), tier_discount + extra)
            if rng.random() < 0.18:
                add_line(order, rng.choice(by_channel[("HORECA", "ACCS")]), rng.randint(1, 4), tier_discount)
            if rng.random() < 0.004:
                add_line(order, rng.choice(by_channel[("HORECA", "EQUIP")]), 1, tier_discount)
            if rng.random() < 0.006:  # free sample of a new origin: legitimate 100 % discount
                add_line(order, rng.choice(by_channel[("HORECA", "BEANS")]), 1, 100.0)
        promo = retail_promo(day)
        for c in retail:
            if c["CreatedDate"] > day or rng.random() >= c["orders_month"] / 30.4 * season("RETAIL", day):
                continue
            order = new_order(c["CustomerId"], "RETAIL", day, f"PROMO{day.year}{day.month:02d}" if promo else None)
            contract = 5.0 if c["Segment"] == "Chain" else 2.0
            for cat, n in (("BEANS", rng.randint(1, 3)), ("GROUND", rng.randint(1, 3)), ("CAPS", rng.randint(1, 4))):
                for p in rng.sample(by_channel[("RETAIL", cat)], n):
                    qty = rng.choice([6, 12, 12, 18, 24])
                    if cat == "CAPS" and promo:
                        add_line(order, p, int(qty * 1.8), contract + 25)
                    else:
                        add_line(order, p, qty, contract)
            if day.month in (11, 12):
                for p in rng.sample(by_channel[("RETAIL", "GIFT")], rng.randint(1, 3)):
                    add_line(order, p, rng.choice([4, 6, 8]), contract)
        code, cats, pct, lift = campaign_for(day)
        expected = 42 * (1.27 ** years_in) * season("ECOM", day) * lift
        for _ in range(int(expected) + (1 if rng.random() < expected % 1 else 0)):
            if ecom_customers and rng.random() < 0.55:
                customer_id = rng.choice(ecom_customers)
            else:
                customer_id = f"E{next_consumer:06d}"
                next_consumer += 1
                ecom_customers.append(customer_id)
            order = new_order(customer_id, "ECOM", day, code)
            equip_share = 0.015 + 0.01 * years_in + (0.07 if code and code.startswith("BF") else 0)
            mix = {"CAPS": 0.34, "BEANS": 0.28, "GROUND": 0.10, "ACCS": 0.12, "EQUIP": equip_share,
                   "GIFT": 0.35 if day.month in (11, 12) else 0.02}
            for _ in range(rng.choices([1, 2, 3], [0.6, 0.3, 0.1])[0]):
                cat = rng.choices(list(mix), list(mix.values()))[0]
                p = rng.choice(by_channel[("ECOM", cat)])
                qty = 1 if cat in ("EQUIP", "GIFT") else rng.choice([1, 1, 2, 3])
                add_line(order, p, qty, pct if cat in cats else 0.0)
        day += timedelta(days=1)
    orders = [o for o in orders if o["lines"]]
    for o in orders:
        lines.extend(o["lines"])
    customers += [{"CustomerId": cid, "CustomerName": f"Online customer {cid[1:]}", "ChannelCode": "ECOM",
                   "Segment": "Consumer", "RegionCode": rng.choices(list(REGIONS), [v[0] for v in REGIONS.values()])[0],
                   "City": None, "CreatedDate": None} for cid in ecom_customers]
    return orders, lines


def fulfil(rng, orders):
    """Cancellation, invoicing and returns for every order."""
    invoices, credit_notes, credit_lines = [], [], []
    cancel_rate = {"ECOM": 0.04, "HORECA": 0.015, "RETAIL": 0.01}
    lag = {"ECOM": (0, 2), "HORECA": (1, 2), "RETAIL": (2, 5)}
    inv_no = cn_no = 0
    for o in orders:
        ordered_at = datetime.combine(o["OrderDate"], datetime.min.time()) + timedelta(minutes=rng.randint(420, 1260))
        o["CreatedAt"] = ordered_at
        if rng.random() < cancel_rate[o["ChannelCode"]]:
            o["Status"], o["CancelledAt"], o["InvoiceDate"] = "Cancelled", ordered_at + timedelta(hours=rng.randint(1, 30)), None
            o["ModifiedAt"] = o["CancelledAt"]
            continue
        invoice_date = o["OrderDate"] + timedelta(days=rng.randint(*lag[o["ChannelCode"]]))
        if invoice_date > END:
            o["Status"], o["CancelledAt"], o["InvoiceDate"], o["ModifiedAt"] = "Open", None, None, ordered_at
            continue
        inv_no += 1
        o["Status"], o["CancelledAt"], o["InvoiceDate"] = "Invoiced", None, invoice_date
        o["InvoiceId"] = f"FV{inv_no:07d}"
        invoiced_at = datetime.combine(invoice_date, datetime.min.time()) + timedelta(hours=rng.randint(8, 19))
        o["ModifiedAt"] = invoiced_at
        invoices.append({"InvoiceId": o["InvoiceId"], "OrderId": o["OrderId"], "InvoiceDate": invoice_date,
                         "ModifiedAt": invoiced_at})
        returns = defaultdict(list)
        for line in o["lines"]:
            cat, ch = line["product"]["CategoryCode"], o["ChannelCode"]
            rate = {("ECOM", "EQUIP"): 0.08, ("ECOM", "ACCS"): 0.03}.get((ch, cat),
                    0.018 if ch == "RETAIL" else 0.01 if ch == "ECOM" else 0.004)
            if line["DiscountPct"] >= 100 or rng.random() >= rate:
                continue
            delay = rng.randint(2, 14) if ch == "ECOM" else rng.randint(5, 30)
            return_date = invoice_date + timedelta(days=delay)
            if return_date > END:
                continue
            qty = line["Quantity"] if ch == "ECOM" else max(1, int(line["Quantity"] * rng.uniform(0.05, 0.5)))
            reason = ("Changed mind" if cat == "EQUIP" and rng.random() < 0.6 else "Defective") if ch == "ECOM" \
                else rng.choice(["Damaged in transit", "Expired", "Damaged in transit"])
            returns[(return_date, reason)].append((line, qty))
        for (return_date, reason), items in returns.items():
            cn_no += 1
            cn_id = f"AB{cn_no:07d}"
            credited_at = datetime.combine(return_date, datetime.min.time()) + timedelta(hours=rng.randint(9, 18))
            credit_notes.append({"CreditNoteId": cn_id, "InvoiceId": o["InvoiceId"], "CreditDate": return_date,
                                 "Reason": reason, "ModifiedAt": credited_at})
            for n, (line, qty) in enumerate(items, 1):
                credit_lines.append({"CreditNoteId": cn_id, "CreditLineNumber": n, "OrderId": o["OrderId"],
                                     "LineNumber": line["LineNumber"], "Quantity": qty, "ModifiedAt": credited_at})
    return invoices, credit_notes, credit_lines


def add_defects(rng, customers, products, orders, invoices, credit_lines, costs):
    defects = {}
    horeca = [c for c in customers if c["ChannelCode"] == "HORECA" and c["CreatedDate"] < date(2022, 1, 1)]
    dup_pairs = []
    for i, c in enumerate(rng.sample(horeca, 25), 1):
        dup = dict(c, CustomerId=f"H9{i:04d}", CreatedDate=date(2024, 1, 1) + timedelta(days=rng.randint(0, 300)))
        customers.append(dup)
        moved = 0
        for o in orders:
            if o["CustomerId"] == c["CustomerId"] and o["OrderDate"] >= dup["CreatedDate"] and rng.random() < 0.5:
                o["CustomerId"] = dup["CustomerId"]
                moved += 1
        dup_pairs.append([c["CustomerId"], dup["CustomerId"], moved])
    defects["duplicate_customers"] = dup_pairs

    missing = [("VEL-BN-03K", 202409), ("VEL-CP-051", 202504)]
    costs[:] = [r for r in costs if (r["ProductId"], r["YearMonth"]) not in missing]
    defects["missing_standard_cost"] = missing

    invoiced = {(o["OrderId"], l["LineNumber"]): l["Quantity"] for o in orders if o["Status"] == "Invoiced" for l in o["lines"]}
    over = rng.sample(credit_lines, 12)
    for cl in over:
        cl["Quantity"] = invoiced[(cl["OrderId"], cl["LineNumber"])] + rng.randint(1, 5)
    defects["returns_above_invoiced_quantity"] = [[cl["CreditNoteId"], cl["CreditLineNumber"]] for cl in over]

    by_order = {o["OrderId"]: o for o in orders}
    early = rng.sample(invoices, 40)
    for inv in early:
        inv["InvoiceDate"] = by_order[inv["OrderId"]]["OrderDate"] - timedelta(days=rng.randint(1, 3))
    defects["invoice_before_order"] = [inv["InvoiceId"] for inv in early]

    no_region = rng.sample([c for c in customers if c["ChannelCode"] == "HORECA"], 30)
    for c in no_region:
        c["RegionCode"] = None
    defects["customers_without_region"] = [c["CustomerId"] for c in no_region]
    return defects


def write_csv(path, header, rows):
    def fmt(v):
        if v is None:
            return ""
        if isinstance(v, datetime):
            return v.strftime("%Y-%m-%d %H:%M:%S")
        if isinstance(v, date):
            return v.isoformat()
        if isinstance(v, bool):
            return "1" if v else "0"
        return str(v)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(header)
        writer.writerows([fmt(r[h]) for h in header] for r in rows)


def write_budget(rng, path, products, customers, orders, costs):
    """Finance's budget workbook: one sheet per year, wide months, title rows, a total row and a few typos."""
    cost = {(r["ProductId"], r["YearMonth"]): r["UnitCost"] for r in costs}
    region_of = {c["CustomerId"]: c["RegionCode"] or "VAL" for c in customers}
    actual = defaultdict(lambda: [0.0, 0.0])  # (year, month, channel, region, category) -> [revenue, profit]
    for o in orders:
        if o["Status"] != "Invoiced":
            continue
        d = o["InvoiceDate"]
        for l in o["lines"]:
            net = l["Quantity"] * l["UnitListPrice"] * (1 - l["DiscountPct"] / 100)
            unit_cost = cost.get((l["ProductId"], d.year * 100 + d.month), l["product"]["base_cost"])
            key = (d.year, d.month, o["ChannelCode"], region_of[o["CustomerId"]], l["product"]["CategoryCode"])
            actual[key][0] += net
            actual[key][1] += net - l["Quantity"] * unit_cost
    names = {"BEANS": "Whole Beans", "GROUND": "Ground Coffee", "CAPS": "Capsules", "GIFT": "Gift Packs",
             "ACCS": "Accessories", "EQUIP": "Equipment"}
    growth = {"ECOM": 0.22, "HORECA": 0.05, "RETAIL": 0.03}
    wb = Workbook()
    wb.remove(wb.active)
    keys = sorted({k[2:] for k in actual})
    for year in (2023, 2024, 2025):
        ws = wb.create_sheet(f"FY{year}")
        ws.append([f"Velmora Coffee Roasters - Budget FY{year}"])
        ws.append(["Amounts in EUR, excluding VAT. Approved by the board in November of the previous year."])
        ws.append([])
        ws.append(["Channel", "Region", "Category", "Measure"] + [date(2000, m, 1).strftime("%b") for m in range(1, 13)])
        totals = [0.0] * 12
        for channel, region, cat in keys:
            revenue, profit = [], []
            for m in range(1, 13):
                base = actual.get((year - 1, m, channel, region, cat)) or actual.get((year, m, channel, region, cat))
                if not base:
                    revenue.append(0)
                    profit.append(0)
                    continue
                prior = (year - 1, m, channel, region, cat) in actual
                rev = base[0] * ((1 + growth[channel]) if prior else 1) * rng.uniform(0.95, 1.05)
                margin = base[1] / base[0] if base[0] else 0  # finance plans the prior-year margin
                revenue.append(round(rev, -2))
                profit.append(round(rev * margin, -2))
            category = names[cat]
            if year == 2024 and cat == "CAPS":
                category = "Capsule"
            if year == 2025 and cat == "ACCS":
                category = "Accesories"
            region_text = region.lower() if year == 2025 and region == "MAD" and channel == "RETAIL" else region
            ws.append([channel, region_text, category, "Net revenue"] + revenue)
            ws.append([channel, region_text, category, "Gross profit"] + profit)
            totals = [t + r for t, r in zip(totals, revenue)]
        ws.append(["Total", None, None, "Net revenue"] + totals)
    wb.save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "data" / "generated"))
    args = parser.parse_args()
    rng = random.Random(args.seed)
    out = Path(args.out)
    (out / "source").mkdir(parents=True, exist_ok=True)
    (out / "budget").mkdir(parents=True, exist_ok=True)

    products = make_products(rng)
    costs = [{"ProductId": p["ProductId"], "YearMonth": m,
              "UnitCost": round(p["base_cost"] * (p["coffee_share"] * green_index(m) + 1 - p["coffee_share"])
                                * rng.uniform(0.99, 1.01), 4),
              "ModifiedAt": datetime(m // 100, m % 100, 1) - timedelta(days=3)} for p in products for m in months()]
    customers = make_customers(rng)
    orders, lines = simulate(rng, products, customers)
    invoices, credit_notes, credit_lines = fulfil(rng, orders)
    defects = add_defects(rng, customers, products, orders, invoices, credit_lines, costs)

    price_rows = []
    for p in products:
        for ch in p["channels"]:
            change = date(2025, 7, 1) if ch == "RETAIL" else date(2025, 2, 1)
            if p["CategoryCode"] in ("BEANS", "GROUND", "CAPS", "GIFT"):
                price_rows.append({"ProductId": p["ProductId"], "ChannelCode": ch, "ValidFrom": START,
                                   "ValidTo": change - timedelta(days=1), "ListPrice": list_price(p, ch, START)})
                price_rows.append({"ProductId": p["ProductId"], "ChannelCode": ch, "ValidFrom": change,
                                   "ValidTo": None, "ListPrice": list_price(p, ch, change)})
            else:
                price_rows.append({"ProductId": p["ProductId"], "ChannelCode": ch, "ValidFrom": START,
                                   "ValidTo": None, "ListPrice": list_price(p, ch, START)})
    for c in customers:
        c["ModifiedAt"] = EXTRACTED_AT - timedelta(days=30)
    by_order = {o["OrderId"]: o for o in orders}
    for l in lines:
        l["ModifiedAt"] = by_order[l["OrderId"]]["CreatedAt"]
    for p in products:
        p["ModifiedAt"] = datetime(2022, 12, 15)

    src = out / "source"
    write_csv(src / "products.csv", ["ProductId", "ProductName", "CategoryCode", "PackSize", "LaunchDate", "VatRate",
                                     "IsFood", "ModifiedAt"], products)
    write_csv(src / "price_list.csv", ["ProductId", "ChannelCode", "ValidFrom", "ValidTo", "ListPrice"], price_rows)
    write_csv(src / "standard_cost.csv", ["ProductId", "YearMonth", "UnitCost", "ModifiedAt"], costs)
    write_csv(src / "customers.csv", ["CustomerId", "CustomerName", "ChannelCode", "Segment", "RegionCode", "City",
                                      "CreatedDate", "ModifiedAt"], customers)
    write_csv(src / "sales_orders.csv", ["OrderId", "CustomerId", "ChannelCode", "OrderDate", "CampaignCode",
                                         "Status", "CreatedAt", "CancelledAt", "ModifiedAt"], orders)
    write_csv(src / "sales_order_lines.csv", ["OrderId", "LineNumber", "ProductId", "Quantity", "UnitListPrice",
                                              "DiscountPct", "VatRate", "ModifiedAt"], lines)
    write_csv(src / "invoices.csv", ["InvoiceId", "OrderId", "InvoiceDate", "ModifiedAt"], invoices)
    write_csv(src / "credit_notes.csv", ["CreditNoteId", "InvoiceId", "CreditDate", "Reason", "ModifiedAt"],
              credit_notes)
    write_csv(src / "credit_note_lines.csv", ["CreditNoteId", "CreditLineNumber", "OrderId", "LineNumber", "Quantity",
                                              "ModifiedAt"], credit_lines)
    write_budget(rng, out / "budget" / "Velmora_Budget_FY2023-2025.xlsx", products, customers, orders, costs)
    (out / "defects.json").write_text(json.dumps(defects, indent=1, default=str), encoding="utf-8")

    status = defaultdict(int)
    for o in orders:
        status[o["Status"]] += 1
    print(f"seed {args.seed} -> {out}")
    print(f"products {len(products)}, customers {len(customers)}, orders {len(orders)} {dict(status)}, "
          f"lines {len(lines)}, invoices {len(invoices)}, credit notes {len(credit_notes)} "
          f"({len(credit_lines)} lines)")


if __name__ == "__main__":
    main()
