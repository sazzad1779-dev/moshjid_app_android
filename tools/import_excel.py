#!/usr/bin/env python3
"""Import the mosque ledger .xlsx into the Supabase `transactions` table.

Dry-run by default. Prints a full mapping report and writes nothing.

  python3 tools/import_excel.py
  python3 tools/import_excel.py --apply
  python3 tools/import_excel.py --apply --type-source excel
  python3 tools/import_excel.py --emit-sql > import.sql
"""

import argparse
import json
import re
import sys
import uuid
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

import openpyxl

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sync_categories import ROOT, TXN_TABLE, load_env, authenticate, read_all

XLSX = ROOT / "মধ্য বেপারীপাড়া মোহাম্মদিয়া  জামে মসজিদ.xlsx"
SHEET = "transactions"

NAME_MAP = {
    "sazzad": "Sazzad", "sazz": "Sazzad", "sa": "Sazzad", "s": "Sazzad",
    "kamal": "Kamal",
    "shimul": "Shimul",
    "shofiq": "Shofiq",
}
FALLBACK_OPERATOR = "Mosque Device"

CATEGORY_MAP = {
    "friday collection": ("Friday Collection", "income"),
    "regular donation": ("Regular Donation", "income"),
    "electricity bill": ("Electricity Bill", "expense"),
    "imam salary": ("Imam Hadiya", "expense"),
    "maintenance": ("Maintenance", "expense"),
}
CATEGORY_MAP_OVERRIDE = {
    "regular donation (বাহিরের দানবাক্স)": ("Donation (Outside Box)", "income"),
}

# Some Excel categories exist under both income and expense. Route each to the
# category row whose type matches the sheet's own type column, so a genuine
# "Income / Imam Salary" row lands on Imam Hadiya (income) while an
# "Expense / Imam Salary" row stays on Imam Hadiya (expense). The ledger also
# records donations earmarked for the electricity bill and maintenance, which
# must keep their Income type instead of flipping to the expense category.
CATEGORY_TYPE_AWARE = {
    ("imam salary", "income"): ("Imam Hadiya", "income"),
    ("electricity bill", "income"): ("Electricity Bill", "income"),
    ("maintenance", "income"): ("Maintenance", "income"),
}

CONFLICT_DEFAULT = ("Regular Donation", "income")
EXPENSE_HINTS = ["মেরামত", "প্লাস্টার", "কেনা", "খরচ", "বিল", "repair", "plaster", "purchase"]
EXPENSE_HINT_CATEGORY = {
    "imam salary": ("Imam Hadiya", "expense"),
    "electricity bill": ("Electricity Bill", "expense"),
    "maintenance": ("Maintenance", "expense"),
}
DONATION_WORDS = ["দান", "donation", "চাঁদা", "জমা"]
PURPOSE_WORDS = ["বাবদ", "বাবদে", "হিসাবে", "খরচে"]

BN_MONTHS = "জানুয়ারী|ফেব্রুয়ারী|মার্চ|এপ্রিল|মে|জুন|জুলাই|আগস্ট|সেপ্টেম্বর|অক্টোবর|নভেম্বর|ডিসেম্বর|জানুয়ারি|ফেব্রুয়ারি"
DONOR_BN = re.compile(
    r"^(?:দান\s+দিয়েছেন\s+)?(?:মো[:ঃ]?\s*|মাওঃ\s*)?(.+?)(?:\s+ভাই)?\s*(?:\((?:[^)]*)\))?$"
)

METHOD_KEYWORDS = ["cash", "bkash", "nagad", "bank", "card", "other"]
TYPE_ENUM = {"income", "expense", "other"}
METHOD_ENUM = set(METHOD_KEYWORDS)

COL = {
    "timestamp": 0, "email": 1, "date": 2, "type": 3, "category": 4,
    "description": 5, "amount": 6, "payment_method": 7, "entered_by": 8,
    "notes": 9, "receipt_photo": 10,
}

DONOR_RE = re.compile(r"^donation\s+by\s+(.+?)(?:\s+bhai)?$", re.IGNORECASE)


def base_category(raw):
    return re.sub(r"\s*\([^)]*\)\s*$", "", str(raw or "").strip()).strip().lower()


def resolve_category(raw, excel_type=None):
    low = str(raw or "").strip().lower()
    if low in CATEGORY_MAP_OVERRIDE:
        return CATEGORY_MAP_OVERRIDE[low]
    base = base_category(raw)
    if excel_type and (base, excel_type) in CATEGORY_TYPE_AWARE:
        return CATEGORY_TYPE_AWARE[(base, excel_type)]
    return CATEGORY_MAP.get(base)


def resolve_method(raw):
    low = str(raw or "").strip().lower()
    for k in METHOD_KEYWORDS:
        if k in low:
            return k
    return None


def resolve_operator(raw):
    key = str(raw or "").strip().lower()
    return NAME_MAP.get(key)


DONOR_BLOCKLIST = {
    "donation", "donations", "n/a", "na", "-", "anonymous", "magrib", "desk",
    "others", "other", "unknown", "cash", "income", "expense", "khata",
}


MONTH_WORD = (r"(?:january|february|march|april|may|june|july|august|september|october|november|december"
              r"|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec"
              r"|জানুয়ারী|ফেব্রুয়ারী|মার্চ|এপ্রিল|মে|জুন|জুলাই|আগস্ট|সেপ্টেম্বর|অক্টোবর|নভেম্বর|ডিসেম্বর"
              r"|জানুয়ারি|ফেব্রুয়ারি)")
HONORIFIC = r"(?:md|mohammad|muhammad|মো|মাও)[:.]?"
NAME_START = re.compile(rf"^\s*(?:{HONORIFIC}\s+)?(.+)$", re.IGNORECASE)


def clean_donor_name(s):
    s = re.sub(r"\([^)]*\)", " ", str(s or ""))
    s = re.sub(rf"^\s*{HONORIFIC}\s+", " ", s, flags=re.IGNORECASE)
    s = re.sub(r"\b(?:bhai|vai|ভাই|ভাইয়া)\b", " ", s, flags=re.IGNORECASE)
    s = re.sub(rf"\b{MONTH_WORD}\b", " ", s, flags=re.IGNORECASE)
    s = re.sub(r"[\d,]", " ", s)
    s = re.sub(r"[()\[\]।|,:;.\-–—/\\]", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def extract_donor(description):
    d = str(description or "").strip()
    if not d or d.lower() in DONOR_BLOCKLIST:
        return None

    m = DONOR_RE.match(d)
    if m:
        name = clean_donor_name(m.group(1))
        return name or None

    if re.match(rf"^\s*{HONORIFIC}\s+\S", d, re.IGNORECASE):
        name = clean_donor_name(d)
        if name and len(name) >= 3 and name.lower() not in DONOR_BLOCKLIST:
            return name
        return None

    low = d.lower()
    if not (any(w in low for w in DONATION_WORDS) or re.search(BN_MONTHS, d)):
        return None
    if any(h in low for h in EXPENSE_HINTS) and not any(w in low for w in DONATION_WORDS):
        return None

    inner = re.search(r"মো[:ঃ]?\s*([^()]+?)\s*(?:ভাই)?\s*\)", d)
    if inner:
        cand = clean_donor_name(inner.group(1))
        if (2 < len(cand) <= 60 and not any(h in cand.lower() for h in EXPENSE_HINTS)
                and not any(w in cand for w in PURPOSE_WORDS)):
            return cand

    cleaned = re.sub(rf"^\s*{HONORIFIC}\s+", " ", d, flags=re.IGNORECASE)
    cleaned = re.sub(r"^(দান\s+দিয়েছেন|দান|donation(\s+by)?)", "", cleaned.strip(), flags=re.IGNORECASE)
    name = clean_donor_name(cleaned)
    if not name or len(name) < 3 or name.lower() in DONOR_BLOCKLIST:
        return None
    if any(w in name.lower() for w in DONATION_WORDS):
        return None
    if any(w in name for w in PURPOSE_WORDS):
        return None
    if any(h in name.lower() for h in EXPENSE_HINTS):
        return None
    if not re.search(r"[a-zA-Z\u0980-\u09FF]", name):
        return None
    return name


def reclassify(desc, excel_category_base):
    low = str(desc or "").lower()
    if any(w in low for w in DONATION_WORDS):
        return CONFLICT_DEFAULT, "donation-explicit"
    if any(h in low for h in EXPENSE_HINTS):
        return EXPENSE_HINT_CATEGORY.get(excel_category_base, CONFLICT_DEFAULT), "expense-hint"
    return CONFLICT_DEFAULT, "donation-default"


def norm_date(v):
    if isinstance(v, datetime):
        return v.strftime("%Y-%m-%d")
    if v:
        return str(v)[:10]
    return None


def load_rows():
    wb = openpyxl.load_workbook(XLSX, data_only=True)
    ws = wb[SHEET]
    rows = []
    for r in ws.iter_rows(min_row=2, values_only=True):
        if not any(x is not None for x in r):
            continue
        if r[COL["amount"]] is None:
            continue
        rows.append(r)
    return rows


def build_records(rows, cats_by_key, type_source):
    records, problems, review = [], [], []
    stats = Counter()

    for n, r in enumerate(rows, start=2):
        excel_type = str(r[COL["type"]] or "").strip().lower().split(" ")[0]
        if excel_type not in TYPE_ENUM:
            excel_type = None
        cat = resolve_category(r[COL["category"]], excel_type)

        if cat is None:
            problems.append(f"row {n}: unmapped category {r[COL['category']]!r}")
            stats["unmapped_category"] += 1
            continue

        cat_name, cat_type = cat
        raw_desc = str(r[COL["description"]] or "").strip()
        conflict = bool(excel_type and excel_type != cat_type)
        rule = "as-is"

        if conflict and type_source == "reclassify":
            new_cat, rule = reclassify(raw_desc, base_category(r[COL["category"]]))
            cat_name, cat_type = new_cat
            stats[f"rule:{rule}"] += 1
        elif conflict and type_source == "category":
            rule = "category"
        elif conflict:
            rule = "excel"

        if type_source == "category" and not conflict:
            final_type = cat_type
        elif type_source == "excel" and not conflict:
            final_type = excel_type or cat_type
        elif conflict and type_source == "category":
            final_type = cat_type
        elif conflict and type_source == "excel":
            final_type = excel_type
        elif conflict:
            final_type = cat_type
        else:
            final_type = excel_type if excel_type else cat_type

        method = resolve_method(r[COL["payment_method"]])
        if method is None:
            problems.append(f"row {n}: unmapped payment method {r[COL['payment_method']]!r}")
            stats["unmapped_method"] += 1
            continue

        operator = resolve_operator(r[COL["entered_by"]])
        if operator not in PROFILES_TO_CREATE:
            stats["operator_remapped"] += 1
            stats[f"remap:{operator}->{OPERATOR_FALLBACK}"] += 1
            operator = OPERATOR_FALLBACK
        else:
            stats[f"op:{operator}"] += 1

        if conflict:
            stats["type_conflict"] += 1
            stats[f"flip:{excel_type}->{final_type}"] += 1

        desc = raw_desc
        notes = str(r[COL["notes"]] or "").strip()
        if notes and notes.lower() not in ("n/a", "na", "-"):
            desc = f"{desc} | Note: {notes}" if desc else notes

        date = norm_date(r[COL["date"]])
        if not date:
            problems.append(f"row {n}: missing date")
            stats["missing_date"] += 1
            continue

        ts = r[COL["timestamp"]]
        client_created_at = ts.strftime("%Y-%m-%dT%H:%M:%S.%f") if isinstance(ts, datetime) else None

        rec = {
            "id": str(uuid.uuid4()),
            "type": final_type,
            "amount": float(r[COL["amount"]]),
            "payment_method": method,
            "status": "confirmed",
            "is_deleted": False,
            "date": date,
            "description": desc or None,
            "donor_name": extract_donor(desc),
            "receipt_url": (str(r[COL["receipt_photo"]]).strip()
                            or None) if r[COL["receipt_photo"]] else None,
            "excel_category": str(r[COL["category"]] or "").strip(),
            "excel_type": str(r[COL["type"]] or "").strip(),
            "excel_entered_by": str(r[COL["entered_by"]] or "").strip(),
            "operator": operator,
            "_category_key": (cat_name, cat_type),
        }
        if client_created_at:
            rec["client_created_at"] = client_created_at
        records.append(rec)
        stats["total"] += 1
        if rec["donor_name"]:
            stats["donor_extracted"] += 1

        if conflict:
            review.append({
                "excel_row": n,
                "date": date,
                "amount": rec["amount"],
                "excel_type": rec["excel_type"],
                "excel_category": rec["excel_category"],
                "new_type": final_type,
                "new_category": cat_name,
                "rule": rule,
                "donor_name": rec["donor_name"] or "",
                "description": desc,
            })

    return records, problems, stats, review


def ensure_profiles(supa, names, apply_changes):
    existing = {str(p.get("full_name", "")).strip().lower(): p for p in read_all(supa, "profiles")}
    result = {}
    missing = []
    for nm in sorted(set(names)):
        if nm not in PROFILES_TO_CREATE:
            continue
        hit = existing.get(nm.lower())
        if nm in PROFILE_ID_OVERRIDE and PROFILE_ID_OVERRIDE[nm]:
            result[nm] = PROFILE_ID_OVERRIDE[nm]
        elif hit:
            result[nm] = hit["id"]
        else:
            missing.append(nm)
    if missing:
        print(f"  profiles missing (will be created on --apply): {missing}")
        for nm in missing:
            if not apply_changes:
                continue
            r = supa.post("profiles", {
                "full_name": nm, "role": "collector", "status": "active",
            }, prefer="return=representation")
            if r.status_code not in (200, 201):
                sys.exit(f"Failed creating profile {nm}: {r.status_code} {r.text[:300]}")
            result[nm] = r.json()[0]["id"]
            print(f"  created profile {nm} -> {r.json()[0]['id']}")
    return result, missing


def report(records, stats, problems, cats_by_key, type_source):
    print("=" * 74)
    print("MAPPING REPORT")
    print("=" * 74)
    print(f"rows read          : {stats['total'] + stats['unmapped_category'] + stats['unmapped_method'] + stats['missing_date']}")
    print(f"rows ready to insert: {stats['total']}")
    print(f"unmapped category  : {stats['unmapped_category']}")
    print(f"unmapped method    : {stats['unmapped_method']}")
    print(f"missing date       : {stats['missing_date']}")

    print(f"\n-- operator (profiles) --")
    for k, v in sorted(stats.items()):
        if k.startswith("op:"):
            print(f"  {k[3:]:16} {v:4}")
    for k, v in sorted(stats.items()):
        if k.startswith("remap:"):
            print(f"  {k[6:]:28} {v:4}  (no profile -> {OPERATOR_FALLBACK})")

    print(f"\n-- type --")
    print(f"  source: {type_source}")
    print(f"  excel type conflicts with category: {stats['type_conflict']}")
    for k, v in sorted(stats.items()):
        if k.startswith("rule:"):
            print(f"    rule {k[5:]:18} {v}")
    for k, v in sorted(stats.items()):
        if k.startswith("flip:"):
            print(f"    {k[5:]:20} {v}")

    print(f"\n-- category -> transactions.category_id --")
    used = Counter(r["_category_key"] for r in records)
    for (name, typ), cnt in sorted(used.items()):
        cid = cats_by_key.get((name, typ), {}).get("id")
        print(f"  {name:26} [{typ:7}] {cnt:4}  -> {cid or '!! CATEGORY MISSING !!'}")

    print(f"\n-- donor_name extracted: {stats['donor_extracted']} --")
    donors = Counter(r["donor_name"] for r in records if r["donor_name"])
    for d, c in donors.most_common():
        print(f"  {d:22} {c}")

    print(f"\n-- totals --")
    for t in ("income", "expense", "other"):
        s = sum(r["amount"] for r in records if r["type"] == t)
        n = sum(1 for r in records if r["type"] == t)
        if n:
            print(f"  {t:8} {n:4} rows  {s:>12,.2f}")
    ti = sum(r["amount"] for r in records if r["type"] == "income")
    te = sum(r["amount"] for r in records if r["type"] == "expense")
    print(f"  {'NET':8} {'':4}       {ti - te:>12,.2f}")

    if problems:
        print(f"\n-- problems ({len(problems)}) --")
        for p in problems[:25]:
            print(f"  {p}")
        if len(problems) > 25:
            print(f"  ... and {len(problems) - 25} more")


def apply_records(supa, records, profile_ids, categories, collector_id):
    wanted = ["id", "type", "amount", "payment_method", "status", "is_deleted",
              "entered_by", "date", "collector_id", "category_id",
              "description", "donor_name", "receipt_url", "client_created_at"]
    keys = [k for k in wanted if k in TXN_COLUMNS]
    dropped = [k for k in wanted if k not in TXN_COLUMNS]
    if dropped:
        print(f"  schema: skipping columns absent from {TXN_TABLE}: {dropped}")
    payload = []
    for r in records:
        op = r["operator"]
        pid = profile_ids.get(op)
        if not pid:
            sys.exit(f"No profile id for operator {op!r}; refusing to insert NULL entered_by")
        cat = categories.get(r["_category_key"])
        row = {
            "id": r["id"],
            "type": r["type"],  # dropped when the column no longer exists
            "amount": r["amount"],
            "payment_method": r["payment_method"],
            "status": "confirmed",
            "is_deleted": False,
            "entered_by": pid,
            "date": r["date"],
            "collector_id": collector_id,
            "category_id": cat["id"] if cat else None,
            "description": r.get("description"),
            "donor_name": r.get("donor_name"),
            "receipt_url": r.get("receipt_url"),
            "client_created_at": r.get("client_created_at"),
        }
        payload.append({k: row[k] for k in keys})

    ok = 0
    for i in range(0, len(payload), 50):
        chunk = payload[i:i + 50]
        resp = supa.post(TXN_TABLE, chunk, prefer="return=minimal")
        if resp.status_code not in (200, 201):
            sys.exit(f"Insert failed at chunk {i // 50} ({resp.status_code}): {resp.text[:500]}")
        ok += len(chunk)
        print(f"  inserted {ok}/{len(payload)}")
    return ok


PROFILES_TO_CREATE = ["Sazzad", "Kamal"]
OPERATOR_FALLBACK = "Sazzad"
COLLECTOR_NAME = "Sazzad"

# Fill this in if the profiles cannot be read back over the REST API (RLS hides
# other users' rows). Copy the ids from Supabase -> Table Editor -> profiles.
# Leave empty to let the script look them up.
# Fallback used when the table is empty and cannot be sampled for its columns.
TXN_COLUMNS_FALLBACK = {
    "id", "category_id", "member_id", "monthly_due_id", "donor_name", "donor_phone",
    "collector_id", "amount", "payment_method", "gateway_reference", "status",
    "description", "receipt_number", "receipt_url", "date", "entered_by",
    "approved_by", "created_at", "updated_at", "is_deleted", "deleted_at",
    "deleted_by", "rejection_reason", "client_created_at", "synced_at",
}
TXN_COLUMNS = None

PROFILE_ID_OVERRIDE = {
    "Sazzad": "d1164f3c-47c7-4d5b-98ab-f8a190bd894d",
    "Kamal": "ae637963-091f-4948-8559-8b2e4610bc4a",
}


def emit_profile_sql(names):
    print("-- Create the operator profiles referenced by transactions.entered_by.")
    print("-- Run in Supabase Dashboard > SQL Editor. Safe to run repeatedly.")
    print("-- entered_by is NOT NULL, so these must exist before importing.")
    print()
    for nm in names:
        print("insert into profiles (id, full_name, role, status)")
        print(f"select gen_random_uuid(), '{nm}', 'collector', 'active'")
        print("where not exists (")
        print("  select 1 from profiles where lower(full_name) = lower('" + nm + "')")
        print(");")
        print()


def emit_sql(records, cats_by_key):
    print("-- Generated by tools/import_excel.py")
    print("-- entered_by values are placeholders; resolve UUIDs before running.")
    print()
    for r in records:
        cid = cats_by_key.get(r["_category_key"], {}).get("id")
        vals = [f"'{r['id']}'", str(r["amount"]),
                f"'{r['payment_method']}'", "'confirmed'", "false",
                f"'{r['date']}'", "'ENTERED_BY_UUID'"]
        if cid:
            vals.append(f"'{cid}'")
        if r.get("description"):
            vals.append("'" + r["description"].replace("'", "''") + "'")
        if r.get("donor_name"):
            vals.append("'" + r["donor_name"].replace("'", "''") + "'")
        cols = "id, amount, payment_method, status, is_deleted, date, entered_by"
        if cid:
            cols += ", category_id"
        if r.get("description"):
            cols += ", description"
        if r.get("donor_name"):
            cols += ", donor_name"
        print(f"insert into transactions ({cols}) values ({', '.join(vals)});")
    print()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="commit the import")
    ap.add_argument("--type-source", choices=["category", "reclassify", "excel"], default="category",
                    help="category (default) takes type from CATEGORY_MAP; "
                         "reclassify guesses from description; excel trusts the sheet")
    ap.add_argument("--emit-sql", action="store_true", help="print transaction INSERTs and exit")
    ap.add_argument("--emit-profiles-sql", action="store_true", help="print profile INSERTs and exit")
    ap.add_argument("--yes", action="store_true", help="skip confirmation")
    args = ap.parse_args()

    if args.emit_profiles_sql:
        authenticate(load_env())
        emit_profile_sql(PROFILES_TO_CREATE)
        return

    supa = authenticate(load_env())

    global TXN_COLUMNS
    probe = supa.get(TXN_TABLE, query="select=*", limit=1)
    if probe.status_code != 200:
        sys.exit(f"Cannot read {TXN_TABLE}: {probe.status_code} {probe.text[:200]}")
    if probe.json():
        TXN_COLUMNS = set(probe.json()[0].keys())
    else:
        TXN_COLUMNS = set(TXN_COLUMNS_FALLBACK)
        print("schema: table is empty, using known column list")
    print(f"transactions columns: {sorted(TXN_COLUMNS)}")
    if "type" not in TXN_COLUMNS:
        print("schema: 'type' is gone; type is derived from transaction_categories.type")

    cats = read_all(supa, "transaction_categories")
    cats_by_key = {(c["name"], c["type"]): c for c in cats}
    print(f"loaded {len(cats)} categories, {len(read_all(supa, 'profiles'))} profiles")

    rows = load_rows()
    print(f"read {len(rows)} data rows from '{SHEET}'")

    records, problems, stats, review = build_records(rows, cats_by_key, args.type_source)

    if review:
        import csv
        rv = ROOT / "tools" / "_backup" / "reclassified_rows.csv"
        rv.parent.mkdir(parents=True, exist_ok=True)
        with rv.open("w", newline="", encoding="utf-8-sig") as fh:
            w = csv.DictWriter(fh, fieldnames=list(review[0].keys()))
            w.writeheader()
            w.writerows(review)
        print(f"reclassification review -> {rv.relative_to(ROOT)} ({len(review)} rows)")

    if args.emit_sql:
        emit_sql(records, cats_by_key)
        return

    report(records, stats, problems, cats_by_key, args.type_source)

    names = {r["operator"] for r in records}
    print("\n" + "=" * 74)
    print(f"profiles needed: {sorted(names)}")
    ensure_profiles(supa, names, args.apply)

    if not args.apply:
        print("\nDRY RUN - nothing written. Re-run with --apply.")
        return

    if problems:
        print(f"\nWARNING: {len(problems)} rows will be skipped.")

    if not args.yes:
        if input(f"\nInsert {len(records)} transactions? [y/N] ").strip().lower() != "y":
            print("aborted")
            return

    profile_ids, _ = ensure_profiles(supa, names, True)

    bdir = ROOT / "tools" / "_backup"
    bdir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    bp = bdir / f"import_plan_{stamp}.json"
    bp.write_text(json.dumps(records, indent=2, ensure_ascii=False))
    print(f"plan backup: {bp.relative_to(ROOT)}")

    print("\ninserting...")
    collector_id = profile_ids.get(COLLECTOR_NAME)
    print(f"collector_id -> {COLLECTOR_NAME} ({collector_id})")
    ok = apply_records(supa, records, profile_ids, cats_by_key, collector_id)
    print(f"\ndone. inserted {ok} transactions.")

    final = read_all(supa, TXN_TABLE)
    print(f"table now holds {len(final)} rows")


if __name__ == "__main__":
    main()
