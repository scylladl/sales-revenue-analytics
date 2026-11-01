"""
Loads the synthetic ERP exports (data/generated/source/*.csv) into the src schema of VelmoraSales.

Replaces the previous content of every src table, inside one transaction. Windows authentication, no stored
passwords. Needs pyodbc (requirements.txt) and the Microsoft ODBC Driver 18 for SQL Server.

Usage: python database/load_source_data.py [--server localhost]
"""
import argparse
import csv
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

import pyodbc

DATA = Path(__file__).resolve().parent.parent / "data" / "generated" / "source"

# CSV file -> target table, parents before children
FILES = {
    "products.csv": "src.Product",
    "customers.csv": "src.Customer",
    "price_list.csv": "src.PriceList",
    "standard_cost.csv": "src.StandardCost",
    "sales_orders.csv": "src.SalesOrder",
    "sales_order_lines.csv": "src.SalesOrderLine",
    "invoices.csv": "src.Invoice",
    "credit_notes.csv": "src.CreditNote",
    "credit_note_lines.csv": "src.CreditNoteLine",
}

PARSERS = {
    "date": date.fromisoformat,
    "datetime2": datetime.fromisoformat,
    "decimal": Decimal,
    "int": int,
    "smallint": int,
    "bit": lambda text: text == "1",
}


def table_columns(cursor, table):
    schema, name = table.split(".")
    cursor.execute(
        "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS"
        " WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION",
        schema, name,
    )
    return cursor.fetchall()


def read_rows(path, columns):
    with path.open(encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        missing = [name for name, _ in columns if name not in reader.fieldnames]
        if missing:
            raise SystemExit(f"{path.name} has no column {', '.join(missing)}")
        parsers = [(name, PARSERS.get(data_type, str)) for name, data_type in columns]
        # the exports write NULL as an empty field
        return [tuple(None if row[name] == "" else parse(row[name]) for name, parse in parsers) for row in reader]


def main():
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("--server", default="localhost")
    args = parser.parse_args()

    connection = pyodbc.connect(
        f"Driver={{ODBC Driver 18 for SQL Server}};Server={args.server};Database=VelmoraSales;"
        "Trusted_Connection=yes;TrustServerCertificate=yes",
        autocommit=False,
    )
    cursor = connection.cursor()
    cursor.fast_executemany = True
    try:
        for table in reversed(FILES.values()):
            cursor.execute(f"DELETE FROM {table}")
        for file, table in FILES.items():
            path = DATA / file
            if not path.exists():
                raise SystemExit(f"Missing {path}. Run generator/generate_data.py first.")
            columns = table_columns(cursor, table)
            rows = read_rows(path, columns)
            names = ", ".join(name for name, _ in columns)
            marks = ", ".join("?" for _ in columns)
            cursor.executemany(f"INSERT INTO {table} ({names}) VALUES ({marks})", rows)
            print(f"{table:<20} {len(rows):>8} rows")
        connection.commit()
    except BaseException:
        connection.rollback()
        raise
    finally:
        connection.close()


if __name__ == "__main__":
    main()
