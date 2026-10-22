# ZNN-Docker

Run a [Zenon Network](https://zenon.network) node (`znnd` from
[go-zenon](https://github.com/zenon-network/go-zenon)) — optionally as a
Pillar producer — in Docker, **without** `znn-controller` and without systemd
units.

- Builds `znnd` from the official source at a release tag (amd64 and arm64)
- One command to build the newest release, one to update, one to roll back
- Several independent instances on one host (e.g. `main`, `test`, `next`)
- `producer-keygen`: creates the producer keystore and writes the `Producer`
  block in `config.json`, using go-zenon's own wallet code

## Why not znn-controller?

`znn-controller` (last release v0.0.4-alpha) does five things on *Deploy*:
configure NTP, write a systemd unit `go-zenon.service`, build `znnd`, create a
keystore called `producer` with a random password, and write that into
`~/.znn/config.json`. Everything else — producing momentums as a Pillar — is
built into `znnd` itself. This repo replaces those steps with Docker and a
small Go tool.

## Requirements

- Linux host with Docker Engine + the Compose plugin (`docker compose`)
- `git` and `curl`
- NTP active on the host (`timedatectl` should show *System clock synchronized: yes*)

## Quick start

```bash
git clone <this repo> znn-docker && cd znn-docker
./znn.sh latest            # shows newest go-zenon tag, e.g. v0.0.9-alphanet
./znn.sh init main         # creates instances/main/{.env,data/}
./znn.sh up main           # builds go-zenon:<version> if needed and starts it
./znn.sh status main       # container state + stats.syncInfo (state 2 = synced)
./znn.sh logs main
```

Open the p2p port in your firewall (default `35995`, **TCP and UDP**).
RPC (`35997` HTTP, `35998` WS) listens on `127.0.0.1` only by default.

## Instances

Each instance has its own data directory, ports and version, stored in
`instances/<name>/.env`:

```
INSTANCE=main
ZNN_VERSION=v0.0.9-alphanet
ZNN_PREVIOUS_VERSION=
DATA_DIR=/path/to/znn-docker/instances/main/data
P2P_PORT=35995
HTTP_PORT=35997
WS_PORT=35998
RPC_ADDR=127.0.0.1
```

Containers use host networking (no NAT for p2p, and Docker does not bypass
`ufw`), so a second instance needs different ports:

```bash
./znn.sh init test --p2p-port 36995 --http-port 36997 --ws-port 36998
```

`./znn.sh list` shows all instances.

## Updating and rolling back

Images are tagged per version (`go-zenon:v0.0.9-alphanet`), so old versions
stay available locally.

```bash
./znn.sh update main            # build newest tag if needed, switch, restart
./znn.sh update main v0.0.9-alphanet   # or a specific tag
./znn.sh rollback main          # back to the previous version
```

Tip: try a new release on a second instance first, or take a backup:

```bash
./znn.sh backup main            # stops, tars data dir to backups/, starts again
```

## Running a Pillar

There are two different wallets:

| | Pillar (owner) wallet | Producer wallet |
|---|---|---|
| Where | Syrius / hardware wallet, **not** on the server | On the server |
| Holds | ZNN + QSR for the Pillar | Nothing |
| Used for | Registering the Pillar, rewards | Signing momentums |

**Never use your owner wallet as producer**: znnd needs the producer password
in plain text in `config.json`.

1. Let the node sync completely (`./znn.sh status main` → `"state":2`).
2. Create the producer key:
   ```bash
   ./znn.sh keygen main
   ```
   This creates `data/wallet/producer`, generates a random password, backs up
   `config.json` and writes:
   ```json
   "Producer": {
       "Address": "z1q...",
       "Index": 0,
       "KeyFilePath": "producer",
       "Password": "..."
   }
   ```
   Options: `-name <file>`, `-password-file <file>`, `-update-config=false`
   (only print the block), `-force` (replace an existing block).
3. `./znn.sh restart main` — the log shows `Producer address detected: z1q...`.
4. In Syrius, register (or update) your Pillar with that **producer address**.
5. Back up `data/wallet/producer` and `data/config.json` somewhere safe.

> ℹ️ Upstream `znnd` prints its full configuration — including the producer
> password — to stdout on startup. Images built from this repo apply
> [`patches/0001-redact-producer-password-in-logs.patch`](patches/README.md),
> so `docker logs` shows `"Password": "<redacted>"` instead. The password itself
> is still stored in plain text in `config.json` (znnd needs it to unlock the
> keystore), so keep `data/` readable for root and the container user only.

## Migrating an existing node

Copying an already-synced data directory is much faster than syncing from
genesis. Chain data is architecture independent (ARM64 → x86 is fine), but use
the same go-zenon version on both sides.

1. Stop the old node (a running database must not be copied).
2. Copy its data dir (default `~/.znn`) into `instances/<name>/data/`, e.g.
   `rsync -a --info=progress2 old-host:.znn/ instances/main/data/`
3. Do **not** reuse the old node's producer key on two machines at once. Remove
   or replace the `Producer` block in the copied `config.json` (and the old
   `wallet/` keystore if it is not meant to move).
4. `./znn.sh up main` — the script fixes file ownership for the container user.

`DataPath`/`WalletPath` values in an old `config.json` are overridden by the
container's `--data` / `--wallet` flags, so absolute paths like `/root/.znn`
do no harm.

## Files

```
Dockerfile                     multi-stage build: znnd + producer-keygen from a git tag
patches/                       small fixes applied to go-zenon at build time
docker-compose.yml             service template, filled per instance by znn.sh
znn.sh                         build / init / up / update / rollback / keygen / backup
tools/producer-keygen/main.go  keystore generator using go-zenon's wallet package
instances/                     per-instance .env and data (git-ignored)
backups/                       backups (git-ignored)
```

Build arguments: `ZNN_VERSION` (required), `ZNN_REPO`, `ZNN_PATCHES` (default 1), `ZNN_UID`/`ZNN_GID`
(default 1000), `GO_VERSION` (default 1.24), `DEBIAN_VERSION` (default bookworm).
`znn.sh` honours `ZNN_REPO`, `ZNN_UID` and `ZNN_GID` from the environment.

## Disclaimer

Not an official Zenon project. Run a Pillar at your own risk; test on a
non-producing instance first.

## License

GPL-3.0, see [LICENSE](LICENSE). `producer-keygen` links against
[go-zenon](https://github.com/zenon-network/go-zenon), which is GPL-3.0 as well.
