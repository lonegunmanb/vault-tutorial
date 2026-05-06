#!/bin/bash
source /root/setup-common.sh

install_vault &
INSTALL_VAULT_PID=$!

if ! command -v jq > /dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq jq > /dev/null 2>&1
fi

wait "$INSTALL_VAULT_PID"

mkdir -p /root/operator-lab/{logs,data-single,data-raft1,data-raft2,data-raft3,data-migrated-raft}

cat > /root/operator-lab/single.hcl <<'HCL'
disable_mlock = true
ui = false

storage "file" {
  path = "/root/operator-lab/data-single"
}

listener "tcp" {
  address     = "127.0.0.1:8300"
  tls_disable = true
}

api_addr     = "http://127.0.0.1:8300"
cluster_addr = "http://127.0.0.1:8301"
HCL

cat > /root/operator-lab/raft1.hcl <<'HCL'
disable_mlock = true
ui = false

storage "raft" {
  path    = "/root/operator-lab/data-raft1"
  node_id = "raft-1"
}

listener "tcp" {
  address     = "127.0.0.1:8400"
  tls_disable = true
}

api_addr     = "http://127.0.0.1:8400"
cluster_addr = "http://127.0.0.1:8401"
HCL

cat > /root/operator-lab/raft2.hcl <<'HCL'
disable_mlock = true
ui = false

storage "raft" {
  path    = "/root/operator-lab/data-raft2"
  node_id = "raft-2"
}

listener "tcp" {
  address     = "127.0.0.1:8410"
  tls_disable = true
}

api_addr     = "http://127.0.0.1:8410"
cluster_addr = "http://127.0.0.1:8411"
HCL

cat > /root/operator-lab/raft3.hcl <<'HCL'
disable_mlock = true
ui = false

storage "raft" {
  path    = "/root/operator-lab/data-raft3"
  node_id = "raft-3"
}

listener "tcp" {
  address     = "127.0.0.1:8420"
  tls_disable = true
}

api_addr     = "http://127.0.0.1:8420"
cluster_addr = "http://127.0.0.1:8421"
HCL

cat > /root/operator-lab/migrate-file-to-raft.hcl <<'HCL'
storage_source "file" {
  path = "/root/operator-lab/data-single"
}

storage_destination "raft" {
  path    = "/root/operator-lab/data-migrated-raft"
  node_id = "migrated-raft-1"
}

cluster_addr = "http://127.0.0.1:8501"
HCL

cat > /root/operator-lab/start-single.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
cd /root/operator-lab

if [ -f single.pid ]; then
  kill "$(cat single.pid)" > /dev/null 2>&1 || true
  rm -f single.pid
fi

rm -rf data-single logs/single.log
mkdir -p data-single logs

vault server -config="$PWD/single.hcl" > "$PWD/logs/single.log" 2>&1 &
echo $! > single.pid

echo "Waiting for the file-storage Vault server on 127.0.0.1:8300 ..."
for i in $(seq 1 30); do
  status=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8300/v1/sys/health || true)
  if [ "$status" != "000" ]; then
    echo "Server is reachable. It is expected to be uninitialized."
    exit 0
  fi
  sleep 1
done

echo "The server did not become reachable. Last log lines:"
tail -40 logs/single.log || true
exit 1
SCRIPT
chmod +x /root/operator-lab/start-single.sh

cat > /root/operator-lab/activate-single.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
cd /root/operator-lab

export VAULT_ADDR='http://127.0.0.1:8300'

if [ ! -f init.json ]; then
  echo "init.json not found. Run Step 1 initialization first."
  exit 1
fi

ROOT_TOKEN=$(jq -r '.root_token' init.json)
KEY1=$(jq -r '.unseal_keys_b64[0]' init.json)
KEY2=$(jq -r '.unseal_keys_b64[1]' init.json)

printf '%s\n' "$ROOT_TOKEN" > root-token.txt
printf '%s\n' "$KEY1" > unseal-key-1.txt
printf '%s\n' "$KEY2" > unseal-key-2.txt
jq -r '.unseal_keys_b64[2]' init.json > unseal-key-3.txt

sealed=$(curl -sS "$VAULT_ADDR/v1/sys/seal-status" | jq -r '.sealed')
if [ "$sealed" = "true" ]; then
  curl -sS --request PUT --data "$(jq -n --arg key "$KEY1" '{key:$key}')" "$VAULT_ADDR/v1/sys/unseal" > /dev/null
  curl -sS --request PUT --data "$(jq -n --arg key "$KEY2" '{key:$key}')" "$VAULT_ADDR/v1/sys/unseal" > /dev/null
fi

cat > single-env.sh <<EOF
export VAULT_ADDR='http://127.0.0.1:8300'
export VAULT_TOKEN='$ROOT_TOKEN'
EOF

echo "Single-node Vault is active. Run: source /root/operator-lab/single-env.sh"
SCRIPT
chmod +x /root/operator-lab/activate-single.sh

cat > /root/operator-lab/start-raft-cluster.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
cd /root/operator-lab

for pidfile in raft1.pid raft2.pid raft3.pid; do
  if [ -f "$pidfile" ]; then
    kill "$(cat "$pidfile")" > /dev/null 2>&1 || true
    rm -f "$pidfile"
  fi
done

rm -rf data-raft1 data-raft2 data-raft3 logs/raft*.log raft-init.json raft.snap
mkdir -p data-raft1 data-raft2 data-raft3 logs

vault server -config="$PWD/raft1.hcl" > "$PWD/logs/raft1.log" 2>&1 &
echo $! > raft1.pid

echo "Waiting for raft-1 ..."
for i in $(seq 1 30); do
  status=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8400/v1/sys/health || true)
  if [ "$status" != "000" ]; then
    break
  fi
  sleep 1
done

VAULT_ADDR=http://127.0.0.1:8400 vault operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json > raft-init.json

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' raft-init.json)
ROOT_TOKEN=$(jq -r '.root_token' raft-init.json)

echo "Activating raft-1 before joining follower nodes ..."
curl -sS --request PUT --data "$(jq -n --arg key "$UNSEAL_KEY" '{key:$key}')" http://127.0.0.1:8400/v1/sys/unseal > /dev/null

leader_sealed="true"
for i in $(seq 1 30); do
  leader_sealed=$(curl -sS http://127.0.0.1:8400/v1/sys/seal-status | jq -r '.sealed' 2>/dev/null || echo "true")
  if [ "$leader_sealed" = "false" ]; then
    break
  fi
  sleep 1
done

if [ "$leader_sealed" != "false" ]; then
  echo "raft-1 did not become active. Last log lines:"
  tail -40 logs/raft1.log || true
  exit 1
fi

vault server -config="$PWD/raft2.hcl" > "$PWD/logs/raft2.log" 2>&1 &
echo $! > raft2.pid
vault server -config="$PWD/raft3.hcl" > "$PWD/logs/raft3.log" 2>&1 &
echo $! > raft3.pid

echo "Waiting for raft-2 and raft-3 ..."
for port in 8410 8420; do
  for i in $(seq 1 30); do
    status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${port}/v1/sys/health" || true)
    if [ "$status" != "000" ]; then
      break
    fi
    sleep 1
  done
done

VAULT_ADDR=http://127.0.0.1:8410 vault operator raft join http://127.0.0.1:8400 > /dev/null
VAULT_ADDR=http://127.0.0.1:8420 vault operator raft join http://127.0.0.1:8400 > /dev/null

echo "Activating raft-2 and raft-3 ..."
for addr in http://127.0.0.1:8410 http://127.0.0.1:8420; do
  curl -sS --request PUT --data "$(jq -n --arg key "$UNSEAL_KEY" '{key:$key}')" "$addr/v1/sys/unseal" > /dev/null
done

echo "Waiting for the Raft cluster to report all peers ..."
cluster_ready="false"
for i in $(seq 1 30); do
  peers=$(VAULT_ADDR=http://127.0.0.1:8400 VAULT_TOKEN="$ROOT_TOKEN" vault operator raft list-peers 2>/dev/null || true)
  if echo "$peers" | grep -q "raft-2" && echo "$peers" | grep -q "raft-3"; then
    cluster_ready="true"
    break
  fi
  sleep 1
done

if [ "$cluster_ready" != "true" ]; then
  echo "Raft peers did not become ready. Last log lines:"
  tail -40 logs/raft1.log logs/raft2.log logs/raft3.log || true
  exit 1
fi

cat > raft-env.sh <<EOF
export VAULT_ADDR='http://127.0.0.1:8400'
export VAULT_TOKEN='$ROOT_TOKEN'
EOF

echo "Raft cluster is ready. Run: source /root/operator-lab/raft-env.sh"
SCRIPT
chmod +x /root/operator-lab/start-raft-cluster.sh

cat > /root/operator-lab/stop-lab.sh <<'SCRIPT'
#!/bin/bash
cd /root/operator-lab
for pidfile in single.pid raft1.pid raft2.pid raft3.pid; do
  if [ -f "$pidfile" ]; then
    kill "$(cat "$pidfile")" > /dev/null 2>&1 || true
    rm -f "$pidfile"
  fi
done
echo "Lab Vault processes stopped."
SCRIPT
chmod +x /root/operator-lab/stop-lab.sh

cd /root/operator-lab
finish_setup