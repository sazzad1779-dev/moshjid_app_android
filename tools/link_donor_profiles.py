#!/usr/bin/env python3
"""Create `profiles` rows for the people who paid Imam Hadiya, and link them
to their transactions via transactions.member_id.

Dry-run by default. Writes a review CSV of every name decision.

  python3 tools/link_donor_profiles.py
  python3 tools/link_donor_profiles.py --apply
"""

import argparse
import csv
import json
import sys
import unicodedata
import uuid
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sync_categories import ROOT, load_env, authenticate, read_all, psql_exec, psql_query

DONOR_CATEGORY = ("Imam Hadiya", "income")

# normalized variant -> canonical display name.
# Only merge when you are confident these are the same human. Differences of
# case and whitespace merge automatically and need no entry.
ALIASES = {
    "joshim": "Joshim",
    "জসিম": "Joshim",
    "তাইজুল ইসলাম": "Taijul Islam",
    "সোবাহান": "Sobhan",
    "হারুন": "Harun",
    "তানজিল": "Tanzil",
    "সাহেদ": "Saheed",
    "shaheed": "Saheed",
    "shohidul": "Shohidul",
    "shohidul islam": "Shohidul",
    "sohidul islam": "Shohidul",
    "romon bapary": "Roman Bapary",
    "mostofa vai": "Mostofa",
    "liton": "Litton",
    "saidur rahman": "Saidur Rahman",
    "ibrahim": "Ibrahim",
    "mahmud": "Mahmud",
    "yamin": "Yamin",
    "sazzad": "Sazzad",
    "kamal": "Kamal",
    "shimul": "Shimul",
    "shorif": "Shorif",
    "shah alom": "Shah Alom",
    "sukkur ali": "Sukkur Ali",
    "shofiul alom": "Shofiul Alom",
    "billal mia": "Billal Mia",
    "rom an bapary": "Roman Bapary",
    "amin": "Amin",
}

# Explicit display spelling, applied after grouping. Anything not listed keeps
# the most frequently written variant.
DISPLAY = {
    "keramot ali": "Keramat Ali",
    "mustafizur rahman shuvo": "Mustafizur Rahman Shuvo",
    "jamal kazi": "Jamal Kazi",
    "ahsan habib": "Ahsan Habib",
    "shamsul bapary": "Shamsul Bapary",
    "sofiq bepary": "Sofiq Bepary",
    "sha newaj": "Shanewaj",
    "billal mia": "Billal Mia",
    "litton": "Litton",
    "shohidul": "Shohidul",
    "roxi": "Roxi",
    "mintu": "Mintu",
    "osman": "Osman",
    "zakaria": "Zakaria",
    "juwel": "Juwel",
    "alamin": "Alamin",
    "taijul islam": "Taijul Islam",
    "shorif": "Shorif",
    "shimul": "Shimul",
    "shah alom": "Shah Alom",
    "sukkur ali": "Sukkur Ali",
    "sukkur": "Sukkur",
    "shofiul alom": "Shofiul Alom",
    "saidur rahman": "Saidur Rahman",
    "ibrahim": "Ibrahim",
    "mahmud": "Mahmud",
    "yamin": "Yamin",
    "joshim": "Joshim",
    "sazzad": "Sazzad",
    "kamal": "Kamal",
    "saidur rahman ": "Saidur Rahman",
}

NEW_ROLE = "member"
NEW_APPROVAL = "approved"
# These are donors, not collectors. Left off deliberately: profiles.collector_id
# means "the collector assigned to this person", and assigning one here would be
# wrong. Note the RLS consequence in the report.
ASSIGN_COLLECTOR = False


def norm(s):
    s = unicodedata.normalize("NFC", str(s or "")).strip().lower()
    return " ".join(s.split())


def canonical_key(name):
    n = norm(name)
    return norm(ALIASES.get(n, n))


def display_name(key, variants):
    if key in DISPLAY:
        return DISPLAY[key]
    return Counter(variants).most_common(1)[0][0].strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="create profiles and link transactions")
    ap.add_argument("--yes", action="store_true", help="skip confirmation")
    args = ap.parse_args()

    conn = load_env().get("DATABASE_URL")
    if not conn:
        sys.exit("DATABASE_URL missing from .env")

    authenticate(load_env())

    rows = psql_query(conn, f"""
        select t.id, t.donor_name, t.amount, t.date
        from transactions t
        join transaction_categories c on c.id = t.category_id
        where c.name = '{DONOR_CATEGORY[0]}'
          and c.type = '{DONOR_CATEGORY[1]}'
          and t.is_deleted = false
    """)
    print(f"Imam Hadiya (income) transactions: {len(rows)}")
    named = [r for r in rows if r["donor_name"]]
    print(f"  with a donor name : {len(named)}")
    print(f"  without any name   : {len(rows) - len(named)}")

    profiles = psql_query(conn, "select id, full_name, role from profiles")
    by_norm = {norm(p["full_name"]): p for p in profiles}
    print(f"existing profiles: {len(profiles)}")

    groups = defaultdict(list)
    for r in named:
        groups[canonical_key(r["donor_name"])].append(r)

    # Label each group exactly once. Recomputing it later from a differently
    # ordered variant list can pick a different spelling for ties, which then
    # fails to match the id map.
    label_of = {}
    for key, items in groups.items():
        label_of[key] = display_name(key, sorted({i["donor_name"] for i in items}))

    reuse, create = {}, []
    for key, items in sorted(groups.items()):
        label = label_of[key]
        if key in by_norm:
            reuse[label] = by_norm[key]["id"]
        else:
            create.append((label, len(items), sum(float(i["amount"]) for i in items)))

    total = len(reuse) + len(create)
    print("\n" + "=" * 70)
    print(f"distinct people (after merging): {total}")
    print(f"  reuse existing profile : {len(reuse)}")
    print(f"  profiles to create     : {len(create)}")
    print("=" * 70)

    print("\n-- REUSE existing profile --")
    for label, pid in sorted(reuse.items()):
        print(f"  {label:26} -> {pid}  ({by_norm[norm(label)]['full_name']})")

    print(f"\n-- CREATE {len(create)} new profiles (role={NEW_ROLE}) --")
    for name, cnt, amt in create:
        print(f"  {name:26} {cnt:3} payments  {amt:>10,.2f}")

    review = ROOT / "tools" / "_backup" / "donor_profile_review.csv"
    review.parent.mkdir(parents=True, exist_ok=True)
    with review.open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh)
        w.writerow(["profile_name", "action", "profile_id", "payments", "total",
                    "raw_variants", "role"])
        for key, items in sorted(groups.items()):
            variants = sorted({i["donor_name"] for i in items})
            label = label_of[key]
            pid = reuse.get(label)
            w.writerow([
                label,
                "reuse" if pid else "create",
                pid or "",
                len(items),
                f"{sum(float(i['amount']) for i in items):.2f}",
                " | ".join(variants),
                "" if pid else NEW_ROLE,
            ])
    print(f"\nreview -> {review.relative_to(ROOT)}")

    if not args.apply:
        print("\nDRY RUN - nothing written. Re-run with --apply.")
        return

    if not args.yes:
        if input(f"\nCreate {len(create)} profiles and link {total} people? [y/N] ").strip().lower() != "y":
            print("aborted")
            return

    sql = ["begin;"]
    new_ids = {}
    collector_id = None
    if ASSIGN_COLLECTOR:
        hit = next((p for p in profiles if norm(p["full_name"]) == "sazzad"), None)
        if hit:
            collector_id = hit["id"]
            print(f"assigning collector_id -> Sazzad ({collector_id})")
        else:
            print("WARNING: no Sazzad profile found; collector_id left NULL")
    for name, _cnt, _amt in create:
        pid = str(uuid.uuid4())
        new_ids[name] = pid
        safe = name.replace("'", "''")
        coll_col = ", collector_id" if collector_id else ""
        coll_val = f", '{collector_id}'" if collector_id else ""
        sql.append(
            f"insert into profiles (id, full_name, role, status, approval_status, approved_at{coll_col})"
            f" values ('{pid}', '{safe}', '{NEW_ROLE}', 'active', '{NEW_APPROVAL}', now(){coll_val});"
        )
    print(f"\ninserting {len(create)} profiles...")

    all_ids = dict(reuse)
    all_ids.update(new_ids)
    linked = 0
    for key, items in groups.items():
        pid = all_ids[label_of[key]]
        for i in items:
            sql.append(f"update transactions set member_id = '{pid}' where id = '{i['id']}';")
            linked += 1
    sql.append("commit;")
    psql_exec(conn, "\n".join(sql))
    print(f"  linked {linked} transactions across {total} people")

    chk = psql_query(conn, """
        select count(*) total,
               count(member_id) linked
        from transactions t
        join transaction_categories c on c.id=t.category_id
        where c.name='Imam Hadiya' and c.type='income' and t.is_deleted=false
    """)
    print(f"\nverify: {chk[0]['linked']}/{chk[0]['total']} Imam Hadiya rows linked")
    print(f"profiles total: {psql_query(conn, 'select count(*) c from profiles')[0]['c']}")


if __name__ == "__main__":
    main()
