#!/bin/bash
set +e

source /root/setup-common.sh

# ─────────────────────────────────────────────────────────
# 并行：装 vault + 装客户端工具 + 拉 postgres 镜像
# ─────────────────────────────────────────────────────────
install_vault &
INSTALL_VAULT_PID=$!

apt-get update -qq && apt-get install -y -qq postgresql-client jq > /dev/null 2>&1

# 启动 PostgreSQL 容器：postgres:16，super user = root / rootpassword，监听 5432
start_postgres

# ─────────────────────────────────────────────────────────
# 在 PG 内预置：
#   1) 一个供 Vault 使用的"root"账号 vaultadmin（CREATEROLE，便于建/删账号 + 改密）
#   2) 一个供 Step 3 演示 onboarding 的既有账号 legacy_app（带初始密码 legacy-pass）
#   3) 一张演示用数据表 demo.kv 给动态账号 SELECT
# 用 -c 让命令在 PG 已 ready 后顺序执行；重复执行时的 "already exists" 不致命
# ─────────────────────────────────────────────────────────
seed_pg() {
  docker exec -i learn-postgres psql -U root -d postgres -v ON_ERROR_STOP=0 <<'SQL' > /tmp/pg-seed.log 2>&1
-- 1. Vault 自身用的 root：可以 CREATE/ALTER/DROP ROLE
CREATE ROLE vaultadmin WITH LOGIN PASSWORD 'vaultadmin' CREATEROLE;

-- 2. Step 3 onboarding 演示用既有账号
CREATE ROLE legacy_app WITH LOGIN PASSWORD 'legacy-pass';

-- 3. 演示数据
CREATE SCHEMA IF NOT EXISTS demo;
CREATE TABLE IF NOT EXISTS demo.kv (k text PRIMARY KEY, v text);
INSERT INTO demo.kv (k,v) VALUES ('hello','world'),('vault','rocks')
  ON CONFLICT (k) DO NOTHING;

-- vaultadmin 后续要 GRANT SELECT 给临时账号 → 自身得能读
GRANT USAGE ON SCHEMA demo TO vaultadmin;
GRANT SELECT ON ALL TABLES IN SCHEMA demo TO vaultadmin;
ALTER DEFAULT PRIVILEGES IN SCHEMA demo GRANT SELECT ON TABLES TO vaultadmin;

-- legacy_app 也能读（在 step 3 中我们用它的密码登录 PG 验证 onboarding 是否覆盖了密码）
GRANT USAGE ON SCHEMA demo TO legacy_app;
GRANT SELECT ON ALL TABLES IN SCHEMA demo TO legacy_app;
SQL
  return 0
}

count_seeded() {
  docker exec -i learn-postgres psql -U root -d postgres -tAc \
    "SELECT count(*) FROM pg_roles WHERE rolname IN ('vaultadmin','legacy_app');" 2>/dev/null
}

for attempt in 1 2 3 4 5; do
  seed_pg
  n=$(count_seeded)
  if [ "$n" = "2" ]; then
    echo "Seeded PG roles (vaultadmin, legacy_app) on attempt $attempt."
    break
  fi
  echo "Seed attempt $attempt got only $n/2 roles; retrying in 2s..."
  sleep 2
done

if [ "$(count_seeded)" != "2" ]; then
  echo "ERROR: failed to seed PG roles. psql log:"
  cat /tmp/pg-seed.log
fi

# 等 vault 装完
wait "$INSTALL_VAULT_PID"

# 启动 Vault Dev
start_vault_dev

# database/ 引擎留给 step1 自己 enable，完整体验

cd /root
finish_setup
