# Running this fork's CI locally with enact

This fork runs n8n's CI through [enact](https://github.com/tonky/enact): it plans only the
tests a change reaches and starts PostgreSQL and Redis rootless through enve, with no Docker.

## Prerequisites

- git.
- macOS (Apple silicon): a local `/nix/store`. Install Nix once with
  `curl -fsSL https://install.determinate.systems/nix | sh -s -- install`.
- Linux (x86_64, aarch64): nothing else. enve remaps its store in a user namespace.

## Quickstart

```bash
git clone --depth 2 https://github.com/tonky/n8n && cd n8n
./bin/enact setup      # environment, reach map and the commits it was traced at, pnpm install
./bin/enact dry-run    # what the working tree's changes would run, and why
./bin/enact run        # run them
```

- `./bin/enact setup --check` reports the prerequisites and the selected reach map.
- `./bin/enact run -c <package> -j test` runs one job, for example `-c @n8n/ai-utilities`.
- `--rerun` runs tests whose earlier result would otherwise be reused.
- With no reach map, or for files no footprint covers, a suite runs whole: the plan says so.
- Run git from `./bin/enve shell`: setup's `pnpm install` installs n8n's lefthook git hooks,
  which need the environment's node (outside it, `git checkout` and `git commit` fail).
