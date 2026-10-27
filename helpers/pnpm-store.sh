# pnpm-store.sh: sourced by the runners before their first pnpm call.
#
# An unpinned store makes every pnpm command (`pnpm exec`, `pnpm run`, `pnpm turbo`) probe
# where to put it: it creates and deletes `_tmp_<pid>_<hex>` in the directory it runs from
# (pnpm 12's config store_path.rs: can a file there hard link into the pnpm home?). Shards
# run side by side, so that file comes and goes in package directories other shards' tests
# list, and unsettles their footprints. Pinned to the store the install used (its
# node_modules/.modules.yaml records it), it never probes; before an install there is no
# pin, and the install probes once, as it would.
if [ -z "${pnpm_config_store_dir:-}${PNPM_CONFIG_STORE_DIR:-}" ]; then
  pnpm_store_modules="$(dirname "${BASH_SOURCE[0]}")/../node_modules/.modules.yaml"
  if [ -f "$pnpm_store_modules" ]; then
    # JSON (pnpm 12: `"storeDir": "<dir>",`) or YAML (`storeDir: <dir>`).
    pnpm_store_dir=$(sed -n 's/^ *"\{0,1\}storeDir"\{0,1\}: *"\{0,1\}\([^",]*\)"\{0,1\},\{0,1\} *$/\1/p' "$pnpm_store_modules" | head -n 1)
    [ -z "$pnpm_store_dir" ] || export pnpm_config_store_dir="$pnpm_store_dir"
    unset pnpm_store_dir
  fi
  unset pnpm_store_modules
fi
