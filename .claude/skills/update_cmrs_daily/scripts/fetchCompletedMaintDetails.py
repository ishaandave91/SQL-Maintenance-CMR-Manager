import csv
import sys

import pyodbc
from datetime import date, timedelta


ALLOWED_VIEWS = {
    "<DB_CATALOG>.<DB_NAME>.[dbo].[<DB_VIEW_NAME>]",
}


def fetch_completed_maint_details(
    view_name: str,
    start_date: date,
    end_date: date,
    environment: str,
) -> list[dict]:
    """
    Fetch Past Scheduled maintenance rows from the given view within [start_date, end_date).

    Args:
        view_name:  Name of the view — must be in ALLOWED_VIEWS.
        start_date: Inclusive lower bound on PlannedStartDateTime (date only).
        end_date:   Exclusive upper bound on PlannedStartDateTime (date only).

    Returns:
        List of rows as dicts keyed by column name.
    """
    if view_name not in ALLOWED_VIEWS:
        raise ValueError(f"View '{view_name}' is not in the allowed views list.")

    conn_str = (
        f"DRIVER={{ODBC Driver 17 for SQL Server}};"
        f"SERVER=<SQL_SERVER_HOST>;"
        f"DATABASE=master;"
        f"Trusted_Connection=yes;"
        f"TrustServerCertificate=yes;"
    )

    query = (
        f"SELECT * FROM {view_name}"
        " WHERE CAST(PlannedStartDateTime AS date) >= ?"
        "   AND CAST(PlannedStartDateTime AS date) <  ?"
        "   AND Environment =  ?"
    )

    try:
        with pyodbc.connect(conn_str) as conn:
            with conn.cursor() as cursor:
                cursor.execute(query, start_date, end_date, environment)
                columns = [col[0] for col in cursor.description]
                rows = [dict(zip(columns, row)) for row in cursor.fetchall()]
        return rows

    except pyodbc.Error as e:
        print(f"Database error: {e}")
        raise


def _print_rows(rows: list[dict]) -> None:
    if not rows:
        print("0 row(s) returned.")
        return

    # Emit compact CSV to stdout (no fixed-width padding or separators) so the
    # captured output is both token-lean and directly reusable as the saved CSV.
    # The row count goes to stderr to keep stdout pure CSV.
    writer = csv.writer(sys.stdout, lineterminator="\n")
    headers = list(rows[0].keys())
    writer.writerow(headers)
    for row in rows:
        writer.writerow(["" if val is None else val for val in row.values()])
    print(f"{len(rows)} row(s) returned.", file=sys.stderr)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Fetch completed <JIRA_CHANGE_TYPE_LABEL> records from SQL Server."
    )
    parser.add_argument(
        "--start-date",
        metavar="YYYY-MM-DD",
        help="Inclusive lower bound on PlannedStartDateTime (e.g. 2026-05-24). "
             "Defaults to 2 days ago.",
    )
    parser.add_argument(
        "--end-date",
        metavar="YYYY-MM-DD",
        help="Exclusive upper bound on PlannedStartDateTime (e.g. 2026-05-26 to "
             "include records through 2026-05-25). Defaults to today (exclusive, so the previous 2 days are included).",
    )
    args = parser.parse_args()

    if args.start_date and args.end_date:
        start_date = date.fromisoformat(args.start_date)
        end_date = date.fromisoformat(args.end_date)
    else:
        today = date.today()
        start_date = today - timedelta(days=2)
        end_date = today

    results = fetch_completed_maint_details(
        view_name="<DB_CATALOG>.<DB_NAME>.[dbo].[<DB_VIEW_NAME>]",
        start_date=start_date,
        end_date=end_date,
        environment='PROD',
    )
    _print_rows(results)
