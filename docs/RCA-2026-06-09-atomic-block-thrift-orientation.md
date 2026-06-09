# RCA: Hue Atomic Block + Thrift Orientation Unset

## Date
2026-06-09

## Symptoms

- Hue web UI fails with `TransactionManagementError: atomic block` when executing SELECT or INSERT queries via the Hive editor
- CREATE TABLE succeeds in the editor (no error)
- HiveServer2 logs show the query completed successfully (`Time taken: 0.001 seconds`)
- After fixing the atomic block, SELECT queries return empty results with no error shown in the UI
- INSERT then SELECT returns no data even though HS2 log confirms the INSERT ran

## Root Cause #1 — Missing Hue PostgreSQL Database & UserProfile

### Problem
Hue's Django application uses SQLite by default (`/usr/share/hue/desktop/desktop.db`), but SELECT and INSERT queries require saving query history and results to the database. Django's `atomic()` block wraps these DB operations, and when they fail, the entire transaction is poisoned — causing all subsequent operations to fail with "atomic block" errors.

### Why CREATE TABLE Worked
CREATE TABLE is "fire and forget" from Hue's perspective — it sends the SQL to HiveServer2 and returns immediately without persisting any query state to its own database. SELECT and INSERT require Hue to write query history, job status, and result metadata — which failed because:

1. **No `hue` database existed in PostgreSQL.** The Postgres container only had the `metastore` database for Hive.
2. **No `hue` user in PostgreSQL.** Only the `hive` user existed.
3. **`hue.ini` had no `[[database]]` section.** Hue used SQLite by default, which could not handle the concurrent write requirements.
4. **Django migrations had never been run.** The `auth_user` and `useradmin_userprofile` tables did not exist in any properly configured DB.

### The Error Chain
```
User runs SELECT in Hue editor
  → HiveServer2 executes query successfully
  → Hue tries to persist query history (DB write)
  → Django atomic() block: DB operation fails (missing tables/users)
  → Transaction poisoned → every subsequent request → "atomic block" error
```

## Root Cause #2 — TFetchResultsReq Orientation Default = 0 Omitted by Thrift

### Problem
After fixing the atomic block error, SELECT queries still returned empty results. The data was successfully fetched from HiveServer2 but could not be retrieved by Hue.

### Technical Details
Hue uses Thrift TBinaryProtocol to communicate with HiveServer2. The `TFetchResultsReq` struct has this `thrift_spec`:

```python
thrift_spec = (
    None,  # 0
    (1, TType.STRUCT, 'operationHandle', (TOperationHandle, TOperationHandle.thrift_spec), None, ),  # 1
    (2, TType.I32, 'orientation', None, 0, ),  # 2
    (3, TType.I64, 'maxRows', None, None, ),  # 3
    (4, TType.I16, 'fetchType', None, 0, ),  # 4
)
```

The `__init__` default for `orientation` is `thrift_spec[2][4]` which equals `0`. When TBinaryProtocol's fast encoder serializes the struct, it **omits fields whose value equals the `thrift_spec` default** as an optimization.

Since `orientation=0` (FETCH_NEXT) is the default value, the fast encoder omits the field entirely from the wire. Hive 4.2.0 requires this field to be present and raises:

```
Required field 'orientation' is unset!
```

### The Fix
Changed the `thrift_spec` default from `0` to `None`:

```python
# Before
(2, TType.I32, 'orientation', None, 0, )

# After
(2, TType.I32, 'orientation', None, None, )
```

Now `orientation=0 ≠ None`, so the fast encoder always serializes the field. Hive 4.2.0 receives `orientation=0` → maps to `FETCH_NEXT` → returns results successfully.

### Note on TFetchOrientation Enum Values
Hive 4.2.0 (the `apache/hive:4.2.0` Docker image) uses the **legacy** TFetchOrientation mapping:

| Value | Legacy Mapping | Standard Mapping |
|-------|---------------|------------------|
| 0     | FETCH_NEXT    | FETCH_FIRST      |
| 4     | FETCH_FIRST   | (standard has no 4) |

Hue's original enum values (`FETCH_NEXT=0`, `FETCH_FIRST=4`) are **correct** for Hive 4.2.0. Both values work perfectly: `orientation=0` fetches the next batch forward, `orientation=4` resets the cursor and re-fetches from the beginning.

## Root Cause #3 — `if TFetchOrientation.FETCH_FIRST:` Used as Boolean Flag

### Problem
In `apps/beeswax/src/beeswax/server/hive_server2_lib.py`, line ~1128:

```python
if operation_handle.hasResultSet and TFetchOrientation.FETCH_FIRST:
```

`TFetchOrientation.FETCH_FIRST` was used as a truthiness constant (always `True` when `FETCH_FIRST=4`), but the intent was to check only `operation_handle.hasResultSet`. This worked by accident because `FETCH_FIRST=4` is truthy — but it would break if the enum value ever changed to `0`.

### Fix
```python
if operation_handle.hasResultSet:
```

## Fix Applied

### PostgreSQL Setup
```bash
docker exec de-postgres-1 psql -U hive -d metastore -c "CREATE DATABASE hue;"
docker exec de-postgres-1 psql -U hive -d metastore -c "CREATE USER hue WITH PASSWORD 'hue';"
docker exec de-postgres-1 psql -U hive -d metastore -c "GRANT ALL PRIVILEGES ON DATABASE hue TO hue;"
docker exec de-postgres-1 psql -U hive -d hue -c "GRANT ALL ON SCHEMA public TO hue;"
```

### Config Changes
- `config/hue.ini`: Added `[[database]]` section with PostgreSQL connection
- `docker-compose.yml`: Added `postgres` dependency to Hue, added `hue migrate --run-syncdb` to startup
- `docker/hue/Dockerfile` (new): Custom image with Thrift patches baked in

### Thrift Patches
Three files patched in the custom Docker image:
- `/usr/share/hue/build/env/lib/python3.11/site-packages/TCLIService/ttypes.py`
- `/usr/share/hue/apps/beeswax/gen-py/TCLIService/ttypes.py`
- `/usr/share/hue/apps/impala/gen-py/TCLIService/ttypes.py`

Change: `('orientation', None, 0,)` → `('orientation', None, None,)`

### Boolean Flag Fix
One file patched:
- `/usr/share/hue/apps/beeswax/src/beeswax/server/hive_server2_lib.py`

Change: `if operation_handle.hasResultSet and TFetchOrientation.FETCH_FIRST:` → `if operation_handle.hasResultSet:`

## Verification

```bash
$ docker exec -i de-hue-1 DESKTOP_LOG_DIR=/tmp build/env/bin/hue shell <<< '
import django; django.setup()
from beeswax.server.hive_server2_lib import HiveServerClient
from beeswax.server import dbms
from django.contrib.auth.models import User
user = User.objects.get(username="hue")
qs = dbms.get_query_server_config("hiveserver2")
client = HiveServerClient(qs, user)
session = client.open_session(user)
r = client.execute_statement("SELECT * FROM final_test ORDER BY id", session=session)
results = r[0]
if results and results.results and results.results.columns:
    for col in results.results.columns:
        for attr in ["i32Val", "stringVal"]:
            v = getattr(col, attr, None)
            if v is not None:
                print("%s: %s" % (attr, v.values))
'
```

Output:
```
i32Val: [7, 42, 99]
stringVal: ['docker-build', 'works!', 'pg-fix']
```

## Prevention

- Run `hue migrate --run-syncdb` on every container startup (via docker-compose command)
- Ensure PostgreSQL database and user are created in docker-compose or a separate init script
- Verify with `SELECT *` queries through the Hue editor after any config change
- Use the custom `de-hue:local` Docker image built from `docker/hue/Dockerfile` to bake in Thrift patches permanently
