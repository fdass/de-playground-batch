# RCA: Hue Config Ignored — Alphabetical Override Trap

## Date
2026-06-09

## Symptoms
- Hue could not connect to HiveServer2 from the notebook/editor
- Thrift errors connecting to `127.0.0.1:10000` and `::1:10000` instead of `hiveserver2:10000`
- Manually setting `options='{"server_host": "hiveserver2"}'` in `[[[hive]]]` interpreter fixed the editor, but `[beeswax]` `hive_server_host` was still ignored

## Root Cause

### 1. Wrong Config Directory
The Docker volume mount targeted `/hue/desktop/conf/hue.ini`, but Hue reads configs from `/usr/share/hue/desktop/conf/`. The directory `/hue/desktop/conf/` does not exist in the `gethue/hue` image — Docker creates it as an empty directory to satisfy the mount. Hue never scans it. The file was essentially invisible to Hue.

### 2. Alphabetical Override Trap
Hue uses `ConfigObj` to merge all `.ini` files in the config directory **in alphabetical order**. The image ships with:
- `hue.ini` — built-in defaults (all custom values commented out with `##`)
- `z-hue-overrides.ini` — shipped overrides (also all commented out)

Even if the file were in the correct directory, mounting as `hue.ini` (starting with `h`) would load **before** `z-hue-overrides.ini` (`z`), so the override file's (empty) `[beeswax]` section could reset the config.

## Fix
Changed the volume mount in `docker-compose.yml`:

```yaml
# Before (wrong directory, wrong alphabetical position)
- ./config/hue.ini:/hue/desktop/conf/hue.ini:ro

# After (correct directory, loads last alphabetically)
- ./config/hue.ini:/usr/share/hue/desktop/conf/z-hue.ini:ro
```

The `z-` prefix ensures our file loads **after** both `hue.ini` and `z-hue-overrides.ini`, giving it the final word on all values.

## Verification
```bash
docker exec de-hue-1 hue config_dump | grep -E 'hive_server_host|hive_server_port|options'
```
Output:
```
hive_server_host=hiveserver2
hive_server_port=10000
options={'server_host': 'hiveserver2', 'server_port': 10000, 'use_sasl': False}
```

## Prevention
- Mount custom configs to the actual config directory used by Hue: `/usr/share/hue/desktop/conf/`
- Prefix mount target with `z-` to load after all built-in files
- Verify with `hue config_dump` after any config change
