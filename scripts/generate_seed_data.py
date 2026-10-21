"""Generate realistic, internally consistent sample data for the inventory database.

Simulates nine months of trading (1 Jan - 30 Sep 2026) for a small South African
online retailer with three warehouses:

* customers place orders every day, drawn from each product's demand level
* each sale reduces stock in the warehouse that ships it
* when stock drops below a product's reorder level, a purchase order is raised
  and the stock arrives after the supplier's lead time (sometimes late)
* some orders are cancelled or returned

Every stock change is written to stock_movements, so the final inventory table
always equals the sum of the movements. Output: sql/02_seed_data.sql

Usage:
    python scripts/generate_seed_data.py
"""

from __future__ import annotations

import random
from collections import defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

SEED = 42
START = date(2026, 1, 1)
END = date(2026, 9, 30)
OUTPUT = Path(__file__).resolve().parent.parent / "sql" / "02_seed_data.sql"

CATEGORIES = [
    ("Electronics", "Phones, audio and accessories"),
    ("Home & Kitchen", "Appliances and kitchenware"),
    ("Beauty & Personal Care", "Skincare, haircare and grooming"),
    ("Sports & Outdoors", "Fitness and outdoor gear"),
    ("Office & Stationery", "Supplies for home and office"),
    ("Groceries", "Pantry staples and snacks"),
]

# name, email, phone, city, promised lead time (days), how reliable they are (0-1)
SUPPLIERS = [
    ("TechSource Distributors", "orders@techsource.co.za", "011 555 0101", "Johannesburg", 7, 0.85),
    ("HomeWorks Wholesale", "sales@homeworks.co.za", "021 555 0102", "Cape Town", 10, 0.60),
    ("GlowCare Supplies", "trade@glowcare.co.za", "031 555 0103", "Durban", 5, 0.90),
    ("ActiveLife Imports", "buy@activelife.co.za", "012 555 0104", "Pretoria", 14, 0.50),
    ("PaperTrail Office", "info@papertrail.co.za", "041 555 0105", "Gqeberha", 6, 0.95),
    ("Mzansi Pantry Co.", "orders@mzansipantry.co.za", "011 555 0106", "Johannesburg", 3, 0.80),
]

# sku, name, category index, supplier index, cost, price, relative demand
PRODUCTS = [
    ("EL-1001", "Wireless Earbuds", 0, 0, 280.00, 549.00, 2.2),
    ("EL-1002", "USB-C Fast Charger 25W", 0, 0, 95.00, 199.00, 3.5),
    ("EL-1003", "Bluetooth Speaker", 0, 0, 420.00, 799.00, 1.1),
    ("EL-1004", "Smartwatch Fitness Band", 0, 0, 610.00, 1199.00, 0.7),
    ("EL-1005", "Power Bank 20000mAh", 0, 0, 230.00, 449.00, 1.8),
    ("HK-2001", "Air Fryer 4L", 1, 1, 750.00, 1299.00, 0.9),
    ("HK-2002", "Electric Kettle 1.7L", 1, 1, 190.00, 349.00, 1.4),
    ("HK-2003", "Non-stick Pan Set (3 pc)", 1, 1, 340.00, 649.00, 0.6),
    ("HK-2004", "Glass Food Containers (10 pc)", 1, 1, 160.00, 299.00, 0.8),
    ("HK-2005", "Hand Blender 600W", 1, 1, 260.00, 479.00, 0.15),   # slow mover
    ("BP-3001", "Vitamin C Serum 30ml", 2, 2, 85.00, 229.00, 2.8),
    ("BP-3002", "Shea Butter Body Lotion", 2, 2, 55.00, 139.00, 3.0),
    ("BP-3003", "Beard Grooming Kit", 2, 2, 150.00, 349.00, 0.9),
    ("BP-3004", "Hair Clipper Set", 2, 2, 320.00, 599.00, 0.7),
    ("BP-3005", "SPF50 Sunscreen 100ml", 2, 2, 70.00, 179.00, 2.0),
    ("SO-4001", "Yoga Mat 6mm", 3, 3, 120.00, 279.00, 0.9),
    ("SO-4002", "Adjustable Dumbbells 20kg", 3, 3, 890.00, 1599.00, 0.3),
    ("SO-4003", "Hiking Backpack 40L", 3, 3, 410.00, 799.00, 0.5),
    ("SO-4004", "Insulated Water Bottle 1L", 3, 3, 90.00, 229.00, 1.9),
    ("SO-4005", "Camping Chair", 3, 3, 210.00, 449.00, 0.08),     # slow mover
    ("OS-5001", "A4 Printer Paper (5 reams)", 4, 4, 260.00, 429.00, 1.2),
    ("OS-5002", "Gel Pens (12 pack)", 4, 4, 35.00, 89.00, 2.5),
    ("OS-5003", "Ergonomic Office Chair", 4, 4, 1450.00, 2499.00, 0.2),
    ("OS-5004", "Desk Organiser", 4, 4, 75.00, 179.00, 0.6),
    ("OS-5005", "Whiteboard 90x60cm", 4, 4, 230.00, 449.00, 0.1),  # slow mover
    ("GR-6001", "Rooibos Tea (80 bags)", 5, 5, 38.00, 79.00, 4.5),
    ("GR-6002", "Biltong Snack Pack 250g", 5, 5, 85.00, 169.00, 3.8),
    ("GR-6003", "Peanut Butter 800g", 5, 5, 42.00, 89.00, 3.2),
    ("GR-6004", "Filter Coffee 1kg", 5, 5, 120.00, 229.00, 2.1),
    ("GR-6005", "Rusks 500g", 5, 5, 40.00, 85.00, 2.7),
]

# Products that stop selling after a date: these become "dead stock" in the reports.
DISCONTINUED_DEMAND = {"HK-2005": date(2026, 6, 1), "SO-4005": date(2026, 5, 1)}

WAREHOUSES = [
    ("JHB", "Johannesburg Fulfilment Centre", "Johannesburg", 0.5),
    ("CPT", "Cape Town Fulfilment Centre", "Cape Town", 0.3),
    ("DBN", "Durban Fulfilment Centre", "Durban", 0.2),
]

FIRST_NAMES = ["Thabo", "Lerato", "Sipho", "Naledi", "Ayanda", "Kagiso", "Zanele", "Pieter", "Aisha",
               "Lwazi", "Nomvula", "Johan", "Priya", "Bongani", "Refilwe", "Tumelo", "Megan", "Sibusiso",
               "Palesa", "Ruan", "Nandi", "Tshepo", "Fatima", "Mandla", "Lindiwe", "Kyle", "Busisiwe",
               "Themba", "Chantelle", "Musa"]
LAST_NAMES = ["Mokoena", "Dlamini", "Nkosi", "Botha", "Naidoo", "Khumalo", "van der Merwe", "Mahlangu",
              "Pillay", "Zulu", "Sithole", "Smith", "Molefe", "Ndlovu", "Jacobs", "Mthembu", "Pretorius",
              "Maseko", "Govender", "Ngcobo"]
CITIES = [("Johannesburg", "Gauteng"), ("Pretoria", "Gauteng"), ("Soweto", "Gauteng"),
          ("Cape Town", "Western Cape"), ("Stellenbosch", "Western Cape"), ("Durban", "KwaZulu-Natal"),
          ("Pietermaritzburg", "KwaZulu-Natal"), ("Gqeberha", "Eastern Cape"), ("Bloemfontein", "Free State"),
          ("Polokwane", "Limpopo"), ("Mbombela", "Mpumalanga"), ("Rustenburg", "North West")]
CUSTOMER_COUNT = 120

# Roughly how many units the whole shop sells per day; used to size stock.
UNITS_PER_DAY = 7.5
SAFETY_DAYS = 7          # buffer on top of the supplier's lead time
COVER_DAYS = (40, 55)    # how many days of sales one purchase order should cover


def sql_value(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, float)):
        return f"{value:.2f}" if isinstance(value, float) else str(value)
    if isinstance(value, datetime):
        return f"'{value:%Y-%m-%d %H:%M:%S}'"
    if isinstance(value, date):
        return f"'{value:%Y-%m-%d}'"
    return "'" + str(value).replace("'", "''") + "'"


def insert(table: str, columns: list[str], rows: list[tuple], batch: int = 200) -> str:
    """Multi-row INSERT statements, split into batches."""
    out = []
    for i in range(0, len(rows), batch):
        values = ",\n  ".join("(" + ", ".join(sql_value(v) for v in row) + ")" for row in rows[i:i + batch])
        out.append(f"INSERT INTO {table} ({', '.join(columns)}) VALUES\n  {values};")
    return "\n".join(out)


def daterange(start: date, end: date):
    day = start
    while day <= end:
        yield day
        day += timedelta(days=1)


def main() -> None:
    rng = random.Random(SEED)

    # --- reference data ---------------------------------------------------
    customers = []
    used_emails = set()
    for cid in range(1, CUSTOMER_COUNT + 1):
        first, last = rng.choice(FIRST_NAMES), rng.choice(LAST_NAMES)
        email = f"{first}.{last}".lower().replace(" ", "") + f"{cid}@example.co.za"
        used_emails.add(email)
        city, province = rng.choice(CITIES)
        joined = datetime.combine(START - timedelta(days=rng.randint(0, 400)), datetime.min.time()) \
            + timedelta(hours=rng.randint(8, 20))
        customers.append((first, last, email, city, province, joined))
    # A handful of customers who buy far more often than the rest.
    customer_weights = [8 if i < 12 else (3 if i < 40 else 1) for i in range(CUSTOMER_COUNT)]

    # --- stock policy, from each product's share of demand ------------------
    total_demand = sum(p[6] for p in PRODUCTS)
    daily_units = {pid: UNITS_PER_DAY * p[6] / total_demand for pid, p in enumerate(PRODUCTS, start=1)}
    # Reorder point = expected sales during the supplier's lead time plus a safety buffer.
    reorder_level = {pid: max(3, round(daily_units[pid] * (SUPPLIERS[p[3]][4] + SAFETY_DAYS)))
                     for pid, p in enumerate(PRODUCTS, start=1)}

    # --- simulation state -------------------------------------------------
    stock = defaultdict(int)                  # (warehouse_id, product_id) -> qty
    incoming = defaultdict(int)               # (warehouse_id, product_id) -> qty on open POs
    movements = []                            # (product_id, warehouse_id, change, reason, ref, at)
    orders, order_items = [], []
    purchase_orders, po_items = [], []
    arrivals = defaultdict(list)              # date -> [po_id]

    # Opening stock on 1 January, recorded as an adjustment.
    opening = datetime(2026, 1, 1, 7, 0)
    for wid, (_, _, _, share) in enumerate(WAREHOUSES, start=1):
        for pid, p in enumerate(PRODUCTS, start=1):
            qty = max(2, round(daily_units[pid] * share * rng.uniform(40, 60)))
            stock[(wid, pid)] = qty
            movements.append((pid, wid, qty, "adjustment", None, opening))

    order_id = 0
    po_id = 0
    for day in daterange(START, END):
        # 1) Deliveries due today arrive first thing in the morning.
        for pid_po in arrivals.pop(day, []):
            po = purchase_orders[pid_po - 1]
            wid = po[1]
            received_at = datetime.combine(day, datetime.min.time()) + timedelta(hours=8)
            for item in po_items:
                if item[0] == pid_po:
                    _, prod, qty, _ = item
                    stock[(wid, prod)] += qty
                    incoming[(wid, prod)] -= qty
                    movements.append((prod, wid, qty, "purchase", pid_po, received_at))
            purchase_orders[pid_po - 1] = (po[0], po[1], po[2], day, "received")

        # 2) Today's orders. More on weekends and towards month end (payday).
        base = 3.2 + (1.2 if day.weekday() >= 5 else 0) + (1.5 if day.day >= 25 else 0)
        for _ in range(max(0, int(rng.gauss(base, 1.4)))):
            wid = rng.choices([1, 2, 3], weights=[w[3] for w in WAREHOUSES])[0]
            cid = rng.choices(range(1, CUSTOMER_COUNT + 1), weights=customer_weights)[0]
            placed = datetime.combine(day, datetime.min.time()) + timedelta(
                hours=rng.randint(7, 22), minutes=rng.randint(0, 59))

            demand = []
            for pid, p in enumerate(PRODUCTS, start=1):
                stop = DISCONTINUED_DEMAND.get(p[0])
                demand.append(0 if stop and day >= stop else p[6])
            lines = {}
            for _ in range(rng.choices([1, 2, 3, 4], weights=[50, 30, 14, 6])[0]):
                pid = rng.choices(range(1, len(PRODUCTS) + 1), weights=demand)[0]
                lines[pid] = lines.get(pid, 0) + rng.choices([1, 2, 3], weights=[75, 20, 5])[0]

            # Only sell what is actually on the shelf in this warehouse.
            lines = {pid: min(q, stock[(wid, pid)]) for pid, q in lines.items()}
            lines = {pid: q for pid, q in lines.items() if q > 0}
            if not lines:
                continue

            roll = rng.random()
            status = ("cancelled" if roll < 0.04 else "returned" if roll < 0.07 else
                      "pending" if day > END - timedelta(days=2) and roll < 0.5 else
                      "shipped" if day > END - timedelta(days=6) and roll < 0.7 else "delivered")
            order_id += 1
            orders.append((cid, wid, placed, status))
            for pid, qty in lines.items():
                price = PRODUCTS[pid - 1][5]
                discount = rng.choices([0, 5, 10, 15], weights=[80, 10, 7, 3])[0]
                order_items.append((order_id, pid, qty, price, float(discount)))
                if status != "cancelled":
                    stock[(wid, pid)] -= qty
                    movements.append((pid, wid, -qty, "sale", order_id, placed))
                    if status == "returned":
                        back = placed + timedelta(days=rng.randint(3, 10))
                        if back.date() <= END:
                            stock[(wid, pid)] += qty
                            movements.append((pid, wid, qty, "return", order_id, back))

        # 3) End of day: raise purchase orders for anything below its reorder level.
        for wid, (_, _, _, share) in enumerate(WAREHOUSES, start=1):
            due = defaultdict(list)
            for pid, p in enumerate(PRODUCTS, start=1):
                stop = DISCONTINUED_DEMAND.get(p[0])
                if stop and day >= stop:
                    continue  # nobody buys it any more, so nobody reorders it
                level = max(1, round(reorder_level[pid] * share))
                if stock[(wid, pid)] + incoming[(wid, pid)] < level:
                    due[p[3] + 1].append(pid)
            for sid, pids in due.items():
                promised = SUPPLIERS[sid - 1][4]
                reliable = SUPPLIERS[sid - 1][5]
                delay = 0 if rng.random() < reliable else rng.randint(1, max(2, promised // 2))
                arrive = day + timedelta(days=promised + delay)
                po_id += 1
                purchase_orders.append((sid, wid, day, None, "open"))
                for pid in pids:
                    p = PRODUCTS[pid - 1]
                    qty = max(3, round(daily_units[pid] * share * rng.uniform(*COVER_DAYS)))
                    po_items.append((po_id, pid, qty, p[4]))
                    incoming[(wid, pid)] += qty
                if arrive <= END:
                    arrivals[arrive].append(po_id)

    # Purchase orders still open at the end; a couple are cancelled instead.
    for i, po in enumerate(purchase_orders):
        if po[4] == "open" and rng.random() < 0.08:
            purchase_orders[i] = (po[0], po[1], po[2], None, "cancelled")

    # --- write SQL ----------------------------------------------------------
    inventory_rows = [(wid, pid, qty) for (wid, pid), qty in sorted(stock.items())]
    assert all(q >= 0 for _, _, q in inventory_rows), "simulation produced negative stock"

    parts = [
        "-- Generated by scripts/generate_seed_data.py. Do not edit by hand; re-run the script.",
        f"-- {len(orders)} orders, {len(order_items)} order lines, {len(purchase_orders)} purchase orders, "
        f"{len(movements)} stock movements.",
        "USE ecommerce_inventory;",
        "SET FOREIGN_KEY_CHECKS = 0;",
        insert("categories", ["name", "description"], CATEGORIES),
        insert("suppliers", ["name", "contact_email", "phone", "city", "lead_time_days"],
               [s[:5] for s in SUPPLIERS]),
        insert("products", ["sku", "name", "category_id", "supplier_id", "unit_cost", "unit_price",
                            "reorder_level", "is_active", "created_at"],
               [(p[0], p[1], p[2] + 1, p[3] + 1, p[4], p[5], reorder_level[pid], True,
                 datetime(2025, 11, 1, 9, 0)) for pid, p in enumerate(PRODUCTS, start=1)]),
        insert("warehouses", ["code", "name", "city"], [w[:3] for w in WAREHOUSES]),
        insert("customers", ["first_name", "last_name", "email", "city", "province", "created_at"], customers),
        insert("orders", ["customer_id", "warehouse_id", "order_date", "status"], orders),
        insert("order_items", ["order_id", "product_id", "quantity", "unit_price", "discount_pct"], order_items),
        insert("purchase_orders", ["supplier_id", "warehouse_id", "ordered_at", "received_at", "status"],
               purchase_orders),
        insert("purchase_order_items", ["po_id", "product_id", "quantity", "unit_cost"], po_items),
        insert("inventory", ["warehouse_id", "product_id", "quantity_on_hand"], inventory_rows),
        insert("stock_movements", ["product_id", "warehouse_id", "change_qty", "reason", "reference_id",
                                   "moved_at"], sorted(movements, key=lambda m: m[5])),
        "SET FOREIGN_KEY_CHECKS = 1;",
    ]
    OUTPUT.write_text("\n\n".join(parts) + "\n", encoding="utf-8")
    print(f"Wrote {OUTPUT.relative_to(OUTPUT.parent.parent)}: {len(orders)} orders, "
          f"{len(order_items)} order lines, {len(purchase_orders)} purchase orders, {len(movements)} movements")


if __name__ == "__main__":
    main()
