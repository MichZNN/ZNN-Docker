# Local patches

Applied on top of the official go-zenon source during `docker build`
(see the `Dockerfile`). Keep this list short; every patch here is something to
upstream to [go-zenon](https://github.com/zenon-network/go-zenon).

| Patch | Why |
|---|---|
| `0001-redact-producer-password-in-logs.patch` | On startup `znnd` prints its full config as JSON to stdout, including `Producer.Password`. In Docker that ends up in `docker logs` (with systemd: in the journal). The patch prints a copy of the config with the password replaced by `<redacted>`; the real config is unchanged. |

If a new go-zenon release changes the patched code, the build stops with a
clear message. Then either refresh the patch, or build without patches:

```bash
docker build --build-arg ZNN_VERSION=<tag> --build-arg ZNN_PATCHES=0 -t go-zenon:<tag> .
```
