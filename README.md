# MAGPMS Cloud — 5 branches

Fuel station management for Mohamed Abdu Hirna Gomeju Petroleum.

| | |
|---|---|
| Branches | Adama · Dire Dawa · Hirna · Woleciti · Heromaya |
| Tanks | 4 per branch, 50,000 L each — 1 benzil, 3 diesel |
| Capacity | 200,000 L per branch · 1,000,000 L across the group |
| Roles | one central admin over all branches; staff belong to one |
| Stack | static HTML/CSS/JS + Supabase (Postgres + Auth) |

No build step. The pages are served as-is; the only dependency is
`@supabase/supabase-js`, loaded from a CDN in `config.js`.

## Files

```
index.html    sign in / sign up
staff.html    till — sell, shift, tanks, attendance (one branch)
admin.html    all branches — dashboard, prices + history, staff, credit, sales, expenses
config.js     Supabase client, rpc() helper, session guard
ui.js         shared runtime: theme, nav, toasts, dialogs, tank rendering
styles.css    design system
supabase/migrations/   the database this app expects
```

## ⚠ Run the migrations first

**The app will not work against the old database.** It calls a different set
of functions, and none of them take a caller id.

```
0001_identity.sql      link staff to Supabase Auth; current_staff(), is_admin()
0002_stations.sql      stations table, station_id everywhere, tank seeding
0003_price_history.sql append-only price trail
0004_rpcs.sql          every function the pages call
0005_lockdown.sql      RLS on, direct table access revoked
```

Run them in order. **`0005` is not optional** — without it the publishable key
in `config.js` can read every table directly, and the functions become
decoration.

### These migrations are written against an inferred schema

They were derived from what the previous frontend read back — `staff.full_name`,
`sales.total_etb`, `tanks.current_liters`, and so on. Nobody has checked them
against the real database. Dump it and reconcile before running:

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
ORDER BY table_name, ordinal_position;
```

Every line marked `⚠` is a place where a name was guessed.

## Why identity works this way

The previous app passed the caller's own id as a parameter — `p_admin_id`,
read from `localStorage` — while every request used the same anonymous key.
That meant `auth.uid()` was null inside the functions, so **the database had no
way to know who was calling**. Anyone could send any id. Editing one value in
devtools was enough to act as an admin, and it worked equally well with `curl`,
with no browser involved.

Here, identity comes from Supabase Auth. Each request carries the signed-in
user's JWT, `current_staff()` resolves it server-side, and **no function takes a
caller id at all**. The same fix closes a quieter version one tier down: a
cashier could previously pass a colleague's id and file shifts, attendance or
sales against them.

`p_station_id` follows the same rule — it is a *filter* for the admin, never a
grant. Staff are pinned to `current_station()` whatever they send.

## Prices

Prices are per branch: the unique key is `(station_id, fuel_type)`. Previously a
single row per fuel meant setting the diesel price changed it at every site at
once.

Fuels are read from the database, never hard-coded. The old app had `Diesel` and
`Petrol` written into the markup in three places, so a station could not price —
or even ring up — anything else. Renaming a fuel is now an `UPDATE`.

Every change is appended to `price_history` in the same transaction that
updates the price, so the trail cannot miss one. Rows are never edited: a wrong
price is corrected by a new row.

## What was verified, and what was not

Verified in a real browser against a stubbed backend:

- the site rail, consolidated totals, and per-branch views
- price fields rendered from the database, history chart and change log
- the till scoped to one branch, with live pricing
- the role guard — an operator opening `admin.html` lands on `staff.html`
- no console errors on any page

Not verified, because it needs the real database:

- that the migrations run at all against the actual schema
- every RPC's behaviour end to end
- the Auth migration for existing staff (each needs an `auth.users` row before
  they can sign in)

## Deployment

Static hosting. For GitHub Pages: Settings → Pages → deploy from `main`.

Do not add a debug or diagnostic page that calls the RPCs without a session —
the previous repo shipped one, and it exposed staff records, sales history and
customer balances to anyone with the URL.
