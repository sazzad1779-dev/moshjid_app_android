#!/usr/bin/env python3
"""Sync `transaction_categories` in Supabase to the canonical mosque category list.

Safe by default: prints a plan and writes nothing. Use --apply to commit.

  python3 tools/sync_categories.py --dry-run
  python3 tools/sync_categories.py --apply
  python3 tools/sync_categories.py --apply --hard-delete
  python3 tools/sync_categories.py --emit-sql > categories.sql
"""

import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
BACKUP_DIR = ROOT / "tools" / "_backup"
TABLE = "transaction_categories"
TXN_TABLE = "transactions"

# (type, name, bangla). A category name may legitimately appear under more than
# one type: "Imam Hadiya" is money coming IN from monthly donors (81 rows in the
# ledger) and money going OUT to the imam (5 rows). The ledger also collects
# donations earmarked for the electricity bill and maintenance, so those purposes
# need an income row as well as an expense row. They are separate categories
# with separate ids, and lookups must always key on (name, type) -- matching on
# name alone returns an arbitrary one of the two.
CANONICAL = [
    ("income", "Friday Collection", "জুমার দান"),
    ("income", "Regular Donation", "নিয়মিত দান"),
    ("income", "Magrib Donation", "মাগরিব দান"),
    ("income", "Donation (Outside Box)", "বাহিরের দানবাক্স"),
    # The donor side of the imam arrangement. These rows carry donor_name and
    # transactions.member_id -- see tools/link_donor_profiles.py.
    ("income", "Imam Hadiya", "ইমামের হাদিয়া (জমা)"),
    # Donations collected for a specific purpose: the money comes in now and is
    # spent later, so the income and expense sides are separate rows.
    ("income", "Electricity Bill", "বিদ্যুৎ বিল (জমা)"),
    ("income", "Maintenance", "রক্ষণাবেক্ষণ (জমা)"),
    ("income", "Other", "অন্যান্য"),
    ("expense", "Electricity Bill", "বিদ্যুৎ বিল"),
    # The payout side: what the imam is actually paid. No donor.
    ("expense", "Imam Hadiya", "ইমামের হাদিয়া (খরচ)"),
    ("expense", "Maintenance", "রক্ষণাবেক্ষণ"),
    ("expense", "Other", "অন্যান্য"),
]

# Categories whose rows belong to a named donor. Matched on (name, type), not
# name alone, so the expense-side Imam Hadiya never picks up a donor.
DONOR_CATEGORIES = {("Imam Hadiya", "income")}

FK_CANDIDATES = ["category_id", "category_uuid", "category_fk", "category"]

KNOWN_CATEGORY_COLUMNS = {"created_at", "id", "is_active", "name", "type"}

EXTRA_COLUMNS = {}

PRESENT_COLUMNS = None


class Supa:
    def __init__(self, url, key, token):
        self.url = url.rstrip("/")
        self.headers = {
            "apikey": key,
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }

    def get(self, table, query="", limit=1000, offset=0):
        r = requests.get(
            f"{self.url}/rest/v1/{table}",
            headers={**self.headers, "Range": f"{offset}-{offset + limit - 1}"},
            params=query,
            timeout=30,
        )
        return r

    def post(self, table, payload, prefer="return=representation"):
        return requests.post(
            f"{self.url}/rest/v1/{table}",
            headers={**self.headers, "Prefer": prefer},
            json=payload,
            timeout=30,
        )

    def patch(self, table, pk, payload):
        return requests.patch(
            f"{self.url}/rest/v1/{table}",
            headers={**self.headers, "Prefer": "return=representation"},
            params={"id": f"eq.{pk}"},
            json=payload,
            timeout=30,
        )

    def delete(self, table, pk):
        return requests.delete(
            f"{self.url}/rest/v1/{table}",
            headers=self.headers,
            params={"id": f"eq.{pk}"},
            timeout=30,
        )


def load_env():
    env = {}
    f = ROOT / ".env"
    if f.exists():
        for line in f.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    for k in list(env) + list(os.environ):
        if k in os.environ:
            env[k] = os.environ[k]
    return env


def authenticate(env):
    url = env.get("SUPABASE_URL")
    key = env.get("SUPABASE_SERVICE_ROLE_KEY") or env.get("SUPABASE_ANON_KEY")
    if not url or not key:
        sys.exit("Missing SUPABASE_URL or key. Check tools/.env.example or .env")
    if env.get("SUPABASE_SERVICE_ROLE_KEY"):
        print("auth: using SUPABASE_SERVICE_ROLE_KEY (bypasses RLS)", file=sys.stderr)
        return Supa(url, key, key)
    email = env.get("SERVICE_EMAIL")
    password = env.get("SERVICE_PASSWORD")
    if not email or not password:
        sys.exit("No SERVICE_ROLE_KEY and no SERVICE_EMAIL/SERVICE_PASSWORD to sign in with")
    r = requests.post(
        f"{url.rstrip('/')}/auth/v1/token?grant_type=password",
        headers={"apikey": key, "Content-Type": "application/json"},
        json={"email": email, "password": password},
        timeout=30,
    )
    if r.status_code != 200:
        sys.exit(f"Auth failed ({r.status_code}): {r.text[:300]}")
    print(f"auth: signed in as {email} (RLS applies; writes may be blocked)", file=sys.stderr)
    return Supa(url, key, r.json()["access_token"])


def read_all(supa, table, columns="*"):
    rows, offset = [], 0
    while True:
        r = supa.get(table, query=f"select={columns}", limit=1000, offset=offset)
        if r.status_code != 200:
            sys.exit(f"Read {table} failed ({r.status_code}): {r.text[:300]}")
        batch = r.json()
        rows.extend(batch)
        if len(batch) < 1000:
            return rows
        offset += 1000


def _psql(conn, sql, want_rows=False):
    import subprocess
    args = ["psql", conn, "-v", "ON_ERROR_STOP=1"]
    args += ["--csv"] if want_rows else ["-t", "-A"]
    p = subprocess.run(args + ["-c", sql], capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"psql failed: {p.stderr.strip()[:500]}")
    return p.stdout


def psql_query(conn, sql):
    import csv as _csv
    import io
    return list(_csv.DictReader(io.StringIO(_psql(conn, sql, want_rows=True))))


def psql_exec(conn, sql):
    return _psql(conn, sql)


def probe_fk_column(supa):
    for col in FK_CANDIDATES:
        r = supa.get(TXN_TABLE, query=f"select={col}", limit=1)
        if r.status_code == 200:
            print(f"schema: {TXN_TABLE}.{col} exists -> using it as the category FK")
            return col
    print(f"schema: WARNING none of {FK_CANDIDATES} found on {TXN_TABLE}; "
          "reference counts will be skipped and retire mode forced to deactivate")
    return None


def reference_counts(supa, fk_col):
    if not fk_col:
        return {}
    rows = read_all(supa, TXN_TABLE, columns=fk_col)
    counts = {}
    for r in rows:
        v = r.get(fk_col)
        if v:
            counts[v] = counts.get(v, 0) + 1
    return counts


def build_plan(existing, refs, hard_delete):
    by_key = {(r.get("name"), r.get("type")): r for r in existing}
    plan = {"insert": [], "reactivate": [], "retire_deactivate": [], "retire_delete": [], "untouched": []}

    for ctype, name, bn in CANONICAL:
        cur = by_key.get((name, ctype))
        if cur is None:
            plan["insert"].append({"type": ctype, "name": name, "bn": bn, "is_active": True})
        elif cur.get("is_active") is False:
            plan["reactivate"].append(cur)
        else:
            plan["untouched"].append(cur)

    wanted = {(c[1], c[0]) for c in CANONICAL}
    for r in existing:
        if (r.get("name"), r.get("type")) in wanted:
            continue
        if hard_delete and refs.get(r.get("id"), 0) == 0:
            plan["retire_delete"].append(r)
        else:
            plan["retire_deactivate"].append(r)

    return plan


def print_plan(plan, refs):
    def line(kind, rows, show_refs=False):
        print(f"\n{kind}  ({len(rows)})")
        for r in rows:
            label = f"{r.get('name')} [{r.get('type')}]"
            if show_refs:
                print(f"  - {label}  id={r.get('id')}  referenced_by={refs.get(r.get('id'), 0)}")
            else:
                print(f"  + {label}")

    print("=" * 70)
    print("PLAN")
    print("=" * 70)
    line("INSERT (new categories)", plan["insert"])
    line("REACTIVATE", plan["reactivate"])
    line("UNTOUCHED (already correct)", plan["untouched"])
    line("RETIRE", plan["retire_deactivate"] + plan["retire_delete"], show_refs=True)
    print("\n" + "-" * 70)
    print(f"insert={len(plan['insert'])}  reactivate={len(plan['reactivate'])}  "
          f"deactivate={len(plan['retire_deactivate'])}  "
          f"delete={len(plan['retire_delete'])}  untouched={len(plan['untouched'])}")
    blocked = [r for r in plan["retire_delete"] if refs.get(r.get("id"), 0) > 0]
    if blocked:
        print(f"\nSAFETY: {len(blocked)} referenced categories kept (downgraded to deactivate)")


def backup(existing):
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    p = BACKUP_DIR / f"{TABLE}_{stamp}.json"
    p.write_text(json.dumps(existing, indent=2, ensure_ascii=False))
    print(f"backup: {p.relative_to(ROOT)} ({len(existing)} rows)")
    return p


def apply_plan(supa, plan):
    created = {}
    for row in plan["insert"]:
        payload = {"type": row["type"], "name": row["name"], "is_active": True}
        if PRESENT_COLUMNS is not None and "name_bn" in PRESENT_COLUMNS and row.get("bn"):
            payload["name_bn"] = row["bn"]
        payload.update(EXTRA_COLUMNS)
        r = supa.post(TABLE, payload)
        if r.status_code not in (200, 201):
            hint = ""
            if r.status_code in (401, 403) and "row-level security" in r.text:
                hint = ("\n  RLS blocked this write. Fix either way:\n"
                        "    1. set SUPABASE_SERVICE_ROLE_KEY in .env (Supabase Dashboard > API keys)\n"
                        "    2. run: python3 tools/sync_categories.py --emit-sql > categories.sql\n"
                        "       then paste it into the Supabase SQL Editor")
            elif "null value" in r.text or "NOT NULL" in r.text.upper():
                hint = "\n  A NOT NULL column is missing. Add it to EXTRA_COLUMNS at the top of this file."
            else:
                hint = "\n  Unexpected error; nothing was committed."
            sys.exit(f"Insert failed for {row['name']} ({r.status_code}): {r.text[:400]}{hint}")
        created[(row["name"], row["type"])] = r.json()[0]["id"]
        print(f"  inserted {row['name']} [{row['type']}] -> {r.json()[0]['id']}")

    for row in plan["reactivate"]:
        r = supa.patch(TABLE, row["id"], {"is_active": True})
        if r.status_code not in (200, 204):
            sys.exit(f"Reactivate failed for {row['id']}: {r.text[:300]}")
        print(f"  reactivated {row['name']}")

    for row in plan["retire_deactivate"]:
        r = supa.patch(TABLE, row["id"], {"is_active": False})
        if r.status_code not in (200, 204):
            sys.exit(f"Deactivate failed for {row['id']}: {r.text[:300]}")
        print(f"  deactivated {row['name']}")

    for row in plan["retire_delete"]:
        r = supa.delete(TABLE, row["id"])
        if r.status_code not in (200, 204):
            print(f"  WARNING could not delete {row['name']}: {r.text[:200]}")
            continue
        print(f"  deleted {row['name']}")

    return created


def emit_sql(bn_col):
    print("-- Generated by tools/sync_categories.py")
    print("-- Run in Supabase Dashboard > SQL Editor. Safe to run repeatedly.")
    print("-- Does not require a unique constraint on (name, type).")
    bn = ", name_bn" if bn_col else ""
    bn_val = lambda b: f", '{b}'" if bn_col else ""
    print()
    for ctype, name, b in CANONICAL:
        print("insert into transaction_categories (id, name%s, type, is_active)" % bn)
        print(f"select gen_random_uuid(), '{name}'{bn_val(b)}, '{ctype}', true")
        print("where not exists (")
        print("  select 1 from transaction_categories")
        print(f"  where name = '{name}' and type = '{ctype}'")
        print(");")
        print()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="print the plan only (default)")
    ap.add_argument("--apply", action="store_true", help="commit changes")
    ap.add_argument("--hard-delete", action="store_true",
                    help="delete unreferenced old categories instead of deactivating")
    ap.add_argument("--emit-sql", action="store_true", help="print SQL and exit")
    ap.add_argument("--yes", action="store_true", help="skip confirmation")
    args = ap.parse_args()

    if args.emit_sql:
        env = load_env()
        supa = authenticate(env)
        probe = supa.get(TABLE, query="select=*", limit=1)
        if probe.status_code != 200:
            sys.exit(f"Could not read {TABLE}: {probe.text[:300]}")
        cols = set(probe.json()[0].keys()) if probe.json() else KNOWN_CATEGORY_COLUMNS
        emit_sql("name_bn" in cols)
        return

    env = load_env()
    supa = authenticate(env)

    print("probing schema...")
    probe = supa.get(TABLE, query="select=*", limit=1)
    global PRESENT_COLUMNS
    if probe.status_code != 200:
        sys.exit(f"Could not read {TABLE} ({probe.status_code}): {probe.text[:300]}")
    if probe.json():
        PRESENT_COLUMNS = set(probe.json()[0].keys())
    else:
        PRESENT_COLUMNS = set(KNOWN_CATEGORY_COLUMNS)
        print("schema: table is empty, assuming known columns")
    print(f"schema: {TABLE} columns = {sorted(PRESENT_COLUMNS)}")
    fk_col = probe_fk_column(supa)

    existing = read_all(supa, TABLE)
    print(f"found {len(existing)} existing categories in {TABLE}")
    refs = reference_counts(supa, fk_col)

    plan = build_plan(existing, refs, args.hard_delete)
    print_plan(plan, refs)

    if not args.apply:
        print("\nDRY RUN - nothing written. Re-run with --apply to commit.")
        return

    if not args.yes:
        if input("\nApply these changes? [y/N] ").strip().lower() != "y":
            print("aborted")
            return

    backup(existing)
    print("\napplying...")
    apply_plan(supa, plan)

    final = read_all(supa, TABLE)
    active = [r for r in final if r.get("is_active") is not False]
    print(f"\ndone. {len(active)} active categories now in {TABLE}:")
    for r in sorted(active, key=lambda x: (x.get("type", ""), x.get("name", ""))):
        print(f"  {r.get('type'):8} {r.get('name')}  [{r.get('id')}]")


if __name__ == "__main__":
    main()
