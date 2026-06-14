# DE Playground

A containerized Data Engineering playground that replaces traditional HDFS with **MinIO** (S3-compatible object storage). Hive and Spark read/write directly to MinIO via the S3A filesystem connector — no HDFS required.

## Architecture

```
 +----------+     +------------------+     +------------------+
 |   Hue    |---->|  HiveServer2     |---->|  Hive Metastore  |
 |  :8888   |     |  :10000 / :10002 |     |  :9083           |
 +----------+     +------------------+     +--------+---------+
                                                    |
       +--------------------+             +---------+---------+
       |     Spark          |             |    PostgreSQL     |
       | Master :7077/:8080 |             |    :5432          |
       | Worker :8081       |             +-------------------+
       +----------+---------+
                  |
       +----------+---------+
       |      MinIO          |   <--- All data stored here
       |  :9000 API          |        (s3a://warehouse/)
       |  :9001 Console      |
       +---------------------+
```

**Data flow**: Hive and Spark both use the S3A Hadoop connector to read/write Parquet/ORC files directly in MinIO. Hive Metastore tracks table schemas in PostgreSQL; actual data never touches HDFS.

## Quick Start

### Prerequisites

- Docker Engine 24+ and Docker Compose v2+
- ~8 GB free RAM (all containers combined)
- ~5 GB disk space for images

### Setup

```bash
# 1. Build the custom images (adds S3A JARs + AWS SDK)
docker build -t de-hive:3.1.3 docker/hive/
docker build -t de-spark:3.5.5 docker/spark/

# 2. Start the stack
docker compose up -d

# 3. Wait for all services (first start takes ~2 min for schema init)
docker compose ps
```

Expected output — all services healthy:

```
de-hiveserver2-1   Up (healthy)   0.0.0.0:10000->10000, 0.0.0.0:10002->10002
de-metastore-1     Up (healthy)   9083
de-postgres-1      Up (healthy)   5432
de-minio-1         Up (healthy)   0.0.0.0:9000-9001->9000-9001
de-spark-master-1  Up             0.0.0.0:7077->7077, 0.0.0.0:8080->8080
de-spark-worker-1  Up             0.0.0.0:8081->8081
de-hue-1           Up             0.0.0.0:8888->8888
```

### Tear Down

```bash
docker compose down -v   # removes containers + volumes (resets all data)
```

## Access Points

| UI | URL | Description |
|----|-----|-------------|
| **Hue SQL Editor** | [http://localhost:8888](http://localhost:8888) | Web SQL editor (connect to Hive) |
| **MinIO Console** | [http://localhost:9001](http://localhost:9001) | Browse S3 buckets and files |
| **Spark Master UI** | [http://localhost:8080](http://localhost:8080) | Cluster status, running apps |
| **Spark Worker UI** | [http://localhost:8081](http://localhost:8081) | Worker logs and executors |
| **HiveServer2 Web UI** | [http://localhost:10002](http://localhost:10002) | HS2 status page |

**Credentials**:
- MinIO: `minioadmin` / `minioadmin`
- PostgreSQL: `hive` / `hivepass` (database: `metastore`)
- Hue: create an admin user on first login

## Component Matrix

| Service | Image | Port(s) | Role |
|---------|-------|---------|------|
| **MinIO** | `minio/minio:latest` | 9000, 9001 | S3-compatible object storage |
| **PostgreSQL** | `postgres:15` | 5432 | Hive Metastore backend |
| **Hive Metastore** | `de-hive:3.1.3` | 9083 | Table schema registry |
| **HiveServer2** | `de-hive:3.1.3` | 10000, 10002 | SQL query engine (JDBC/Thrift) |
| **Spark Master** | `de-spark:3.5.5` | 7077, 8080 | Cluster manager |
| **Spark Worker** | `de-spark:3.5.5` | 8081 | Task executor |
| **Hue** | `gethue/hue:latest` | 8888 | SQL editor web UI |

## Directory Structure

```
de-playground/
├── docker-compose.yml              # All services, volumes, healthchecks
├── .env                            # Configurable credentials and ports
├── config/
│   ├── core-site.xml               # S3A endpoint for MinIO
│   ├── hive-site.xml               # Metastore URI, JDBC, HS2, tuning
│   ├── spark-defaults.conf         # Spark Hive + S3A defaults
│   ├── hue.ini                     # HiveServer2 connector config
│   └── hive-log4j2.properties      # Log4j2 config (for debugging)
├── docker/
│   ├── hive/
│   │   └── Dockerfile              # FROM apache/hive:3.1.3 + AWS SDK v1
│   └── spark/
│       └── Dockerfile              # FROM apache/spark:3.5.5 + hadoop-aws
└── scripts/
    └── init-hive.sh                # Schema initialization helper
```

## Configuration Notes

### Why custom Docker images?

The base `apache/hive` and `apache/spark` images do not include the AWS S3 filesystem JARs. The custom Dockerfiles add:
- **Hive**: `hadoop-aws` (symlinked from the image's Hadoop tools), `aws-java-sdk-bundle-1.11.271.jar` (AWS SDK v1), `postgresql-42.7.3.jar` (JDBC driver)
- **Spark**: `hadoop-aws-3.3.4.jar`, `aws-java-sdk-bundle-1.12.262.jar`

### Key config properties

| Property | File | Why |
|----------|------|-----|
| `fs.s3a.endpoint=http://minio:9000` | `core-site.xml` | Points S3A to MinIO instead of AWS |
| `fs.s3a.path.style.access=true` | `core-site.xml` | Required for MinIO (no DNS bucket names) |
| `hive.metastore.warehouse.dir=s3a://warehouse/` | `hive-site.xml` | All table data stored in MinIO |
| `hive.execution.engine=mr` | `hive-site.xml` | Uses MapReduce local mode (no YARN needed) |
| `hive.exec.scratchdir=file:///tmp/hive` | `hive-site.xml` | Local scratch dir (Hive 3.x requires 0777 perms on this dir) |
| `hive.server2.authentication=NOSASL` | `hive-site.xml` | No auth for local playground use |
| `COMPOSE_PROJECT_NAME=de` | `.env` | Short project name (avoids DNS FQDN length issues) |
| Network `name: denet` | `docker-compose.yml` | Named network avoids underscore in DNS domain (Hive 3.x URI parser rejects underscores) |
| `hostname: metastore` | `docker-compose.yml` | Metastore container hostname overrides Docker-generated FQDN for Thrift URI compatibility |

### Volume mounts are read-only

Config files in `config/` are mounted as `:ro` (read-only). This prevents the Hive entrypoint's `envsubst` command from overwriting your custom configs via symlink on container reuse.

### Schema initialization

The Metastore entrypoint runs `schematool -dbType postgres -initSchema` automatically on first start. On subsequent starts with `IS_RESUME=true` (set for HiveServer2), schema init is skipped. PostgreSQL data persists across restarts via Docker volumes.

## Sample Usage

### Via Hue Web UI

1. Open [http://localhost:8888](http://localhost:8888)
2. Create an admin account on first login
3. In the left sidebar, select **Hive** as the editor
4. Run queries:

```sql
SHOW DATABASES;
CREATE DATABASE IF NOT EXISTS playground;
USE playground;

CREATE TABLE sample (id INT, name STRING)
STORED AS PARQUET
LOCATION 's3a://warehouse/sample/';

INSERT INTO sample VALUES (1, 'hello'), (2, 'world');
SELECT * FROM sample;
```

### Via beeline

```bash
echo "SHOW DATABASES;" | \
  docker exec -i de-hiveserver2-1 beeline -u 'jdbc:hive2://localhost:10000' --force=true
```

You can also run beeline interactively:

```bash
docker exec -it de-hiveserver2-1 beeline -u 'jdbc:hive2://localhost:10000'
```

### Via Spark SQL

```bash
docker exec -it de-spark-master-1 /opt/spark/bin/spark-sql \
  --master spark://spark-master:7077
```

Then in the Spark SQL shell:
```sql
SHOW DATABASES;
USE playground;
SELECT * FROM sample;
```

### Browse data in MinIO

Open [http://localhost:9001](http://localhost:9001), log in with `minioadmin`/`minioadmin`, and browse the `warehouse` bucket. You'll see Parquet/ORC files generated by Hive and Spark queries.

## Known Issues

### First startup is slow

The initial `docker compose up` downloads ~2.5 GB of images and runs schema initialization. Subsequent starts are fast (~15 seconds).

### Hue fails after fresh start (`docker compose down -v`)

Hue requires the `hue` database and user in PostgreSQL. After a full teardown with volumes (`docker compose down -v`), re-create them:

```bash
docker exec de-postgres-1 psql -U hive -d metastore -c "CREATE DATABASE hue;"
docker exec de-postgres-1 psql -U hive -d metastore -c "CREATE USER hue WITH PASSWORD 'hue';"
docker exec de-postgres-1 psql -U hive -d metastore -c "GRANT ALL PRIVILEGES ON DATABASE hue TO hue;"
docker exec de-postgres-1 psql -U hive -d hue -c "GRANT ALL ON SCHEMA public TO hue;"
docker compose up -d hue
```

### Beeline connection fails in Hive 3.1.3

Hive 3.1.3's beeline has a Thrift binary protocol version handshake issue with HS2 in the same image. Use **spark-sql** or **pyspark** for interactive Hive queries instead:

```bash
docker exec -it de-spark-master-1 /opt/spark/bin/spark-sql --master spark://spark-master:7077
```

### Config file overwrite

## Resources

- [Apache Hive on S3](https://hive.apache.org/development/quickstart/)
- [MinIO S3 Compatibility](https://min.io/docs/minio/linux/developers/security/AWS-SDK.html)
- [Hadoop S3A Connector](https://hadoop.apache.org/docs/stable/hadoop-aws/tools/hadoop-aws/index.html)
- [Hue Documentation](https://docs.gethue.com/)
