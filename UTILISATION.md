# Usage

What `bootstrap.sh` and the database dump do, command by command.

Two scripts, two repositories, two jobs:

| | where | what it is for |
|---|---|---|
| `bootstrap.sh` | `nctorigin-infra` | put the services on a machine |
| `deploy/db.sh` | `nctgame_server` | take the database out and put it back elsewhere |

They meet on a fresh machine: `bootstrap.sh` installs, finds a dump if there is
one, and offers to restore it.

> The scripts themselves speak French — their flags (`--etat`, `--tout`) and
> their variables (`COURRIEL`, `INTERACTIF`) are named in French, and so is
> everything they print. They are quoted here exactly as they are, because a
> command you have to translate before typing is a command you type wrong.

---

# 1. `bootstrap.sh`

```
sudo ./bootstrap.sh                    asks what to install
sudo ./bootstrap.sh nctgame            one service
sudo ./bootstrap.sh nctgame quran      several
sudo ./bootstrap.sh --tout             all four
./bootstrap.sh --etat                  touches nothing
./bootstrap.sh --help                  the script's own help
```

The four known services: **`nctgame`**, **`quran`**, **`whisper`**, **`jitsi`**.

## 1.1 See where things stand

```
./bootstrap.sh --etat
```

No `sudo`, nothing modified. This is the first command to type when you arrive
on a machine you know nothing about.

```
  SERVICE    DOMAINE                          UNITÉ    NGINX    TLS
  nctgame    game.nctorigin.com               actif    posé     oui
  quran      quran-recognizer.nctorigin.com   actif    posé     oui
  whisper    whisper.nctorigin.com            actif    posé     oui
  jitsi      meet.nctorigin.com               actif    posé     oui
```

**`TLS` showing `?` is not a missing certificate**: it means the script is not
allowed to read `/etc/letsencrypt`. Run it again with `sudo` to settle the
question. The distinction is deliberate — confusing "absent" with "I did not
look" has already cost two false trails in this project.

## 1.2 Install

```
sudo ./bootstrap.sh                # it asks
sudo ./bootstrap.sh nctgame        # or you tell it
sudo ./bootstrap.sh --tout
```

It lays the groundwork first — packages, service account, groups, ports — then
each requested service. A service that fails does not stop the others: the final
summary names them, and **running it again resumes where it stopped** without
undoing what succeeded.

An unknown service name is refused **before** `sudo` is required: a typo should
not cost you a password prompt.

## 1.3 Without questions

```
INTERACTIF=0 sudo ./bootstrap.sh --tout
```

Every question then takes its default answer. Useful from another script, or in
an image. **Careful**: with no keyboard, a wait for DNS cannot wait — the script
stops instead of looping.

## 1.4 The variables

| | default | |
|---|---|---|
| `APP_USER` | `whisper` | the account that owns the services |
| `COURRIEL` | *(empty)* | address given to Let's Encrypt |
| `INTERACTIF` | `1` | `0` to ask nothing |

```
APP_USER=jeu COURRIEL=ops@nctorigin.com sudo -E ./bootstrap.sh nctgame
```

`sudo -E` is required for the variables to survive.

## 1.5 What it asks, and why

The script does not stop in front of what it cannot do — it has you do it.

**DNS.** If the domain does not point at the machine yet, it prints the exact
record to create — type, name, value, TTL — then **waits and checks again every
thirty seconds**. You create the entry in another tab, and it carries on by
itself. Without this, certbot fails in a way that explains nothing.

**Advertising** (nctgame). Off by default: with no `data/ads.json`, the server
answers `{"enabled": false}` to everyone, which is the intended state. It asks
before turning it on, and warns that without an AdMob account the app will only
show Google's test blocks.

**The database** (nctgame). If it finds a dump, it offers to restore it. It
**never** replaces an existing database without asking.

**Proof of identity** (nctgame). On a fresh machine there are no older devices
to spare: it offers to require proof from the start, which costs nothing only at
that moment.

**The admin key** (nctgame). Minted, never restored, and never displayed — the
script says where to read it at the moment you need to hand it over.

**The API key** (whisper). Without it the service refuses everyone, its owner
included. It offers to mint one, and warns that it will never be shown again.

**Jitsi** does not install like the others: the script recalls the three things
it cannot do — including **UDP 10000, to be opened in the Hetzner console**,
without which everything looks right and no video gets through — then offers to
run `v3.1-safe`, the only one of the seven scripts that knows the machine
already hosts something else.

## 1.6 Running it again breaks nothing

That is a property, not a tolerance. On an installed machine, `bootstrap.sh`
updates the code, reinstalls dependencies, rewrites the configuration files and
restarts — without duplicating anything.

It is also **the only way to exercise it** without a blank machine at hand: an
install script you run only once is a script you never exercise, and which fails
the day it matters.

It does not touch a repository holding uncommitted changes: it says so and moves
on. Installing cleanly is not worth overwriting someone's work.

---

# 2. `deploy/db.sh` — take the database out, put it back

From `nctgame_server`.

```
deploy/db.sh dump              writes data/dumps/nctgame-<date>.sql.gz
deploy/db.sh dump <file>       writes wherever you want
deploy/db.sh restore <file>    replaces the database with that file
deploy/db.sh list              the dumps at hand
```

## 2.1 Take it out

```
deploy/db.sh dump
```

Works **while the service is running**. Result: a dozen kilobytes.

```
  source : /home/whisper/nctgame_server/data/nctgame.db
  ✓ écrit : data/dumps/nctgame-20260907T162843.sql.gz (12K)
  ✓ vérifié : rechargé, et chaque table a le même effectif
      game_results=444
      players=22
```

The second line is the useful half of the command: **the dump is reloaded into a
throwaway database and compared table by table against the original.** A dump
you cannot read back is not a backup; the check costs a second and turns a hope
into a fact.

**Why not a `cp`.** The database runs in WAL mode: recent writes live in
`nctgame.db-wal` and only enter the main file at the next checkpoint — three
megabytes pending, measured on this machine. Copying `nctgame.db` alone would
give you a database missing everything just played, **and it would open without
an error**, which is the worst way to be wrong.

## 2.2 Put it back

```
deploy/db.sh restore data/dumps/nctgame-20260907T162843.sql.gz
```

Three precautions, in this order:

1. **if the service is running**, it is stopped and restarted — two writers on
   the same file would give two truths;
2. **the current database is set aside**, dated, never overwritten silently.
   Restoring the wrong backup is a mistake you make once, and can only undo if
   the old one still exists;
3. **the new database is built and read in full before anything is replaced.**
   A damaged file is refused and leaves the machine exactly as it was.

Restoring elsewhere — to check a backup, or to prepare another machine — does
not concern the service:

```
NCTGAME_DB=/tmp/essai.db deploy/db.sh restore <file>
```

## 2.3 On a fresh server

```
# here
deploy/db.sh dump
# the file travels however you like: scp, USB stick, email

# over there
sudo ./bootstrap.sh nctgame        # it finds the dump and offers it
```

Or by hand, if the database is already installed:

```
deploy/db.sh restore <file.sql.gz>
```

## 2.4 What the dump does not contain

It contains **the database**: profiles, statistics, game history. Nothing else,
and that is deliberate.

| | where it comes back from |
|---|---|
| `data/ads.json` | a few lines, to rewrite or copy over |
| the admin key | **minted again**, never restored |
| player tokens | in the database — so they travel with the dump |
| the IP → country database | downloaded again by `tools/refresh_geoip.py` |
| game journals | no — diagnostics, not data |
| voice messages | no — they live in `data/voice/` and delete themselves after 24 h |

A secret that travels from one machine to another stops being one: that is why
the admin key is minted again rather than copied.

---

# 3. The other scripts in `nctgame_server/deploy/`

Outside the scope of this guide, but they exist and they look alike:

| | |
|---|---|
| `require-auth.sh` | require proof of identity; `--wipe`, `--revert`, `--status` |
| `open-admin.sh` | open the admin API; `--rotate`, `--close`, `--status` |
| `open-accounts.sh` | override the Apple/Google app identifiers; `--close`, `--status` |

Each carries its own instructions in its header, and a `--status` that changes
nothing.
