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
admin.html    all branches — dashboard, prices + history, staff, shifts,
              tanks + deliveries, credit, sales, expenses, reports
config.js     Supabase client, rpc() helper, session guard
ui.js         shared runtime: theme, nav, toasts, dialogs, tank rendering
styles.css    design system
render.yaml   optional Render deployment (Pages is unaffected)
supabase/migrations/   the database this app expects
```

## ⚠ Run the migrations first

**The app will not work against the old database.** It calls a different set
of functions, and none of them take a caller id.

```
0001_identity.sql        link staff to Supabase Auth; current_staff(), is_admin()
0002_stations.sql        stations table, station_id everywhere, tank seeding
0003_price_history.sql   append-only price trail
0004_rpcs.sql            every function the pages call
0005_lockdown.sql        RLS on, direct table access revoked
0006_delivery_history.sql deliveries recorded, not just applied to the tank
0007_shifts_reports.sql  shift/attendance oversight and the sales report
0008_local_day.sql       "today" means today in Ethiopia, not in UTC
0009_drop_password_hash.sql  remove the dead hashes from the old login system
```

Run them in order. **`0005` is not optional** — without it the publishable key
in `config.js` can read every table directly, and the functions become
decoration.

Each one is idempotent: existence is checked before every alter, and re-running
a migration is a no-op rather than an error.

### Status

**All nine migrations have been applied to the live database.**

`0009` removed `staff.password_hash`, the dead hashes from the login system this
app replaced — a column no code read, produced by a hashing method nobody
established. Current passwords are untouched by it: Supabase Auth keeps those as
bcrypt in `auth.users`, in a schema this app has never been granted access to. RLS is on for
every table in `public`, `anon` and `authenticated` hold no direct table grants,
prices are set per branch, deliveries write to their own trail, and the Shifts
and Reports sections work. The old `admins` table was folded into `staff` by
`0001` and has since been dropped.

Staff are signed up, approved and assigned to branches across all five sites.
Public signup is turned off in Supabase, so a new hire needs an `auth.users` row
created by hand — or signup re-opened for the day.

### "Today" ends at local midnight

`date_trunc('day', now())` is midnight **UTC**, which is 3am in Ethiopia. Before
`0008`, every morning between local midnight and 3am:

- the dashboard's "Sales today" tile still showed yesterday's takings, and added
  this morning's onto them
- a cashier on the early shift saw nothing of their own work in "My Day"

`0008` moved the boundary to local midnight and put the timezone in one place
(`app_timezone()`) instead of a string repeated in each function. Stored data is
untouched: `created_at` stays `timestamptz` in UTC, as it should be. Only the
boundary used to read it back moved.

Confirmed on the live database after applying it — this returns `03:00:00`,
which is both the proof it took and the measure of how wrong the old boundary
was:

```sql
select date_trunc('day', now()) - local_day_start() as difference;
```

## Passwords

Staff set their own password at signup and can reset it themselves from the
sign-in page: **Forgot password?** sends a link, `reset.html` takes the new
one. Before that existed, a forgotten password meant the owner opening the
Supabase dashboard on a laptop — across five branches that is a phone call at
6am to unlock a till.

`reset.html` handles all three shapes of recovery link Supabase has shipped
(`#access_token`, `?token_hash`, `?code`), because which one a project sends
depends on when its email templates were last touched.

### ⚠ This needs one setting in Supabase

**Authentication → URL Configuration** must list the reset page as an allowed
redirect, or the link in the email will drop people on the site root instead
and the flow will appear to do nothing:

```
Site URL:       https://adilabdu52-coder.github.io/magmps3/
Redirect URLs:  https://adilabdu52-coder.github.io/magmps3/reset.html
```

The request form always answers "if that address has an account, a reset link
is on its way", whether or not it does. Saying "no such user" would let anyone
with the URL test addresses and learn who works here, one guess at a time.

### ⚠ And custom SMTP, or resets do not actually send

Supabase's built-in email is capped at roughly **two messages per hour for the
whole project** and is not intended for production. Past that it returns `429`
and sends nothing — and because the form deliberately never confirms whether an
address exists, this looks identical to a successful request. The only place it
shows up is **Logs → Auth Logs**.

That ceiling was hit on the first day of use here, testing. With staff across
five branches, two people forgetting a password on the same morning means the
second one waits an hour.

Set your own SMTP under **Authentication → Emails → SMTP Settings**, then raise
the ceiling under **Authentication → Rate Limits** — it stays at the low default
until custom SMTP is configured, so raising it first does nothing.

**This is done.** Brevo is configured and a real reset has been sent, opened and
completed. Delivery improved as a side effect: mail now comes from a verified
sender rather than Supabase's shared one, which Gmail was filtering.

Brevo suits this better than Resend: Resend's free tier needs a verified
*domain*, while Brevo verifies a single sender address, so no company domain is
required.

```
Host:     smtp-relay.brevo.com
Port:     587
Username: the Brevo SMTP login
Password: the Brevo SMTP key       <- a secret; it belongs in Supabase only
Sender:   the address verified with Brevo
```

None of this is a code change.

### If email is not working, nobody is locked out

An admin can set any password directly: **Authentication → Users** → the row →
**⋯** → update password. That is the fallback for a cashier mid-shift, and it
is how to recover the owner account itself.

## Testing the database contract

`supabase/tests/` rebuilds the post-migration schema on a throwaway Postgres and
runs the migrations against it, so a migration can be checked before it touches
the real database:

```sh
initdb -D /tmp/pgd && pg_ctl -D /tmp/pgd -o '-k /tmp -p 5439' start
psql -h /tmp -p 5439 -d postgres -c 'create role anon' -c 'create role authenticated'
createdb -h /tmp -p 5439 t
psql -h /tmp -p 5439 -d t -v ON_ERROR_STOP=1 -f supabase/tests/fixture.sql
psql -h /tmp -p 5439 -d t -v ON_ERROR_STOP=1 -f supabase/migrations/0007_shifts_reports.sql
psql -h /tmp -p 5439 -d t -v ON_ERROR_STOP=1 -f supabase/migrations/0008_local_day.sql
psql -h /tmp -p 5439 -d t -f supabase/tests/checks.sql
```

Every line should read `PASS`. The checks cover shift variance, report totals,
the local-midnight boundary, and — the ones worth keeping — that
`p_station_id` stays a filter and never a grant, and that a caller with no
session gets nothing.

The fixture is a hand-written copy of the live schema, not a dump. If a column
is ever added or renamed for real, it has to be added here too or these checks
will pass against a schema that no longer exists.

## Browser tests

`tests/browser/` drives the real pages in Chromium with `esm.sh` and every RPC
intercepted, so they run with no network and no database:

```sh
npm install          # dev only - the site still has no build step
npx playwright install chromium
npm test             # static checks, then both browser suites
```

`admin.test.mjs` covers shift variance, report totals, the CSV including its
formula-injection guard, lazy section loading, and that a failed section
retries. `reset.test.mjs` covers all three recovery-link shapes, expired and
already-used links, and that the request form never reveals whether an address
has an account.

These are not wired into CI — the workflow installs nothing, and adding
Playwright to it is a bigger decision than adding the tests was. Run them
before touching `admin.html`, `index.html` or `reset.html`.

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

CI enforces that. `check.mjs` fails the build if a fuel name reappears in an
`<option>`, a `value=`/`data-fuel=` attribute, or a quoted string in a page —
the three shapes the original bug took. Prose may still name a fuel; only the
places that would define a control count.

Every change is appended to `price_history` in the same transaction that
updates the price, so the trail cannot miss one. Rows are never edited: a wrong
price is corrected by a new row.

## What was verified, and what was not

Verified in a real browser against a stubbed backend:

- the site rail, consolidated totals, and per-branch views
- price fields rendered from the database, history chart and change log
- the till scoped to one branch, with live pricing
- the role guard — an operator opening `admin.html` lands on `staff.html`
- shift variance: sign, colour, and a blank for a shift still open
- report totals, trading-day count, and the CSV — including that a branch name
  beginning with `=` is written as text rather than a live formula
- sections fetch only when opened, and a section that failed retries on the
  next visit instead of showing a dead panel
- no console errors on any page

Verified on a throwaway Postgres 16, against the fixture in `supabase/tests/`:

- `0007` and `0008` apply cleanly, and again on a second run
- shift variance, including the blank for a shift still open
- attendance hours, counting up to now for an open check-in
- the local-midnight boundary: a sale at 00:01 local is dropped by the old UTC
  boundary and kept by the new one, and the dashboard tile and report agree
- voided sales excluded from both the tile and the report
- `p_station_id` is a filter, never a grant — an operator passing another
  branch's id gets their own branch back
- a caller with no session gets nothing from any of the new functions

Verified against the real database, by hand:

- all of `0001`–`0008` applied in order
- RLS on for every table; no direct grants to `anon` or `authenticated`
- the local-midnight boundary, which returned `03:00:00` — so the server runs
  on UTC and the bug `0008` fixes was real here, not theoretical
- sign-in, the admin dashboard, per-branch prices and delivery recording
- every approved staff member linked to an `auth.users` row and a branch, with
  none left approved-but-branchless

- the password reset, end to end on the live site and a real phone: request →
  email delivered over Brevo SMTP → link opened → new password set → signed out
  → signed back in with it

Not verified:

- the report against a real month of trade
- shift variance against real meter readings — the column is only meaningful
  if cashiers read the pump rather than deriving the closing figure, and that
  takes a week of use to tell

## Deployment

Static hosting, no build step.

**GitHub Pages** is the live deployment: Settings → Pages → deploy from `main`.

**Render** is optional and additive. `render.yaml` describes the same site as a
Render blueprint; connecting the repo there gives a second URL and nothing about
Pages changes. The reason to bother is response headers, which Pages cannot
send — `render.yaml` sets a CSP that pins `connect-src` to this Supabase project,
so injected code cannot ship a session or a branch's sales elsewhere. Read the
comments in that file before trusting it further than that: the inline module
blocks still require `'unsafe-inline'` for scripts.

Do not add a debug or diagnostic page that calls the RPCs without a session —
the previous repo shipped one, and it exposed staff records, sales history and
customer balances to anyone with the URL.
