#!/usr/bin/env bash
set -euo pipefail

S3_BUCKET="${s3_bucket}"
S3_PREFIX="${s3_prefix}"
REGION="${region}"

apt-get update -y
apt-get install -y ca-certificates curl unzip

# AWS CLI v2
curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

# Docker + Compose plugin
curl -fsSL https://get.docker.com | sh
apt-get install -y docker-compose-plugin
usermod -aG docker ubuntu

mkdir -p /opt/dr-app
cd /opt/dr-app

cat > docker-compose.yml <<'YAML'
services:
  db:
    image: postgres:16
    container_name: dr_db
    environment:
      POSTGRES_DB: orders
      POSTGRES_USER: bayou
      POSTGRES_PASSWORD: bayoupass
    volumes:
      - dbdata:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U bayou -d orders"]
      interval: 5s
      timeout: 3s
      retries: 20

  app:
    image: python:3.12-slim
    container_name: dr_app
    working_dir: /app
    volumes:
      - ./app:/app
    command: bash -c "pip install -r requirements.txt && python app.py"
    environment:
      DB_HOST: db
      DB_PORT: 5432
      DB_NAME: orders
      DB_USER: bayou
      DB_PASSWORD: bayoupass
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "5000:5000"
volumes:
  dbdata:
YAML

mkdir -p app
cat > app/requirements.txt <<'REQ'
flask
psycopg2-binary
REQ

cat > app/app.py <<'PY'
import os, time
from flask import Flask, request, jsonify
import psycopg2

app = Flask(__name__)

def conn():
    return psycopg2.connect(
        host=os.getenv("DB_HOST"),
        port=os.getenv("DB_PORT"),
        dbname=os.getenv("DB_NAME"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"),
    )

for _ in range(30):
    try:
        c = conn(); c.close(); break
    except Exception:
        time.sleep(2)

c = conn()
cur = c.cursor()
cur.execute("""
CREATE TABLE IF NOT EXISTS orders (
  id SERIAL PRIMARY KEY,
  customer TEXT,
  product TEXT,
  quantity INT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
""")
c.commit()
cur.close()
c.close()

@app.get("/health")
def health():
    return {"status":"ok"}

@app.get("/orders")
def get_orders():
    c = conn(); cur = c.cursor()
    cur.execute("SELECT * FROM orders ORDER BY id;")
    rows = cur.fetchall()
    cur.close(); c.close()
    return jsonify(rows)

@app.post("/orders")
def add_order():
    data = request.get_json(force=True)
    c = conn(); cur = c.cursor()
    cur.execute("INSERT INTO orders (customer,product,quantity) VALUES (%s,%s,%s) RETURNING id;",
                (data["customer"], data["product"], int(data["quantity"])))
    oid = cur.fetchone()[0]
    c.commit()
    cur.close(); c.close()
    return {"order_id": oid}, 201

app.run(host="0.0.0.0", port=5000)
PY

cat > restore.sh <<'REST'
#!/usr/bin/env bash
set -euo pipefail

BUCKET="$${1:?Usage: restore.sh <bucket> [prefix]}"
PREFIX="$${2:-backups/}"

LATEST_KEY=$(aws s3api list-objects-v2 \
  --bucket "$BUCKET" \
  --prefix "$PREFIX" \
  --query 'reverse(sort_by(Contents,&LastModified))[0].Key' \
  --output text)

if [[ "$LATEST_KEY" == "None" || -z "$LATEST_KEY" ]]; then
  echo "No backups found in s3://$BUCKET/$PREFIX"
  exit 1
fi

aws s3 cp "s3://$BUCKET/$LATEST_KEY" /tmp/backup.sql.gz

if [ ! -s /tmp/backup.sql.gz ]; then
  echo "Downloaded backup is empty or missing: /tmp/backup.sql.gz"
  exit 1
fi

gunzip -c /tmp/backup.sql.gz > /tmp/backup.sql

if [ ! -s /tmp/backup.sql ]; then
  echo "Extracted SQL is empty or missing: /tmp/backup.sql"
  exit 1
fi

cd /opt/dr-app
docker compose exec -T db psql -U bayou -d orders < /tmp/backup.sql

echo "Restored from $LATEST_KEY"
REST

chmod +x /opt/dr-app/restore.sh

docker compose up -d
sleep 15
/opt/dr-app/restore.sh "$S3_BUCKET" "$S3_PREFIX" || true