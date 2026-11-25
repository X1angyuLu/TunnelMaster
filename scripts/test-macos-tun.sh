#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted || "$(uname -s)" != Darwin ]]; then
  echo "Run this network integration test on a disposable GitHub-hosted macOS runner." >&2
  exit 2
fi

bundle="$(cd "$1" && pwd -P)"
driver="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
tools="$bundle/Contents/Resources/resources"
core="$bundle/Contents/MacOS/tm-mihomo"
service_id="com.x1angyulu.TunnelMaster.verge.service"
installed_core="/Library/Application Support/tunnelmaster-service/cores/tm-mihomo"
ipc="/var/run/tunnelmaster-service/users/$(id -u)/tm-mihomo.sock"
fixture_address="192.0.2.53"
fixture_name="fixture.tunnelmaster.invalid"
requested_answer="192.0.2.123"

scratch="$(mktemp -d "${RUNNER_TEMP}/tunnelmaster-tun.XXXXXXXX")"
chmod 700 "$scratch"
cd "$scratch"
export CLASH_VERGE_TEST_SESSION_TOKEN
CLASH_VERGE_TEST_SESSION_TOKEN="$(openssl rand -hex 32)"
export CLASH_VERGE_TEST_SESSION_GENERATION=""
installed="false"

cleanup() {
  status=$?
  if [[ "$status" != 0 ]]; then
    route -n get -inet "$fixture_address" || true
    sudo -n launchctl print "system/$service_id" || true
  fi
  if [[ -n "$CLASH_VERGE_TEST_SESSION_GENERATION" ]]; then
    "$driver" stop || true
  fi
  if [[ "$installed" == true ]]; then
    sudo -n "$tools/tunnelmaster-service-uninstall" || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

route_interface() {
  route -n get -inet "$1" 2>/dev/null | awk '/interface:/ { print $2 }' || true
}

main_network="$(route_interface 1.1.1.1)"
test -n "$main_network"
initial_fixture_network="$(route_interface "$fixture_address")"
scutil --proxy > proxy-before.txt

cat > fixture.yaml <<'YAML'
mode: rule
log-level: info
allow-lan: false
ipv6: false
geo-auto-update: false
hosts:
  fixture.tunnelmaster.invalid: 192.0.2.123
dns:
  enable: true
  listen: 127.0.0.1:0
  ipv6: false
  use-hosts: true
  enhanced-mode: redir-host
  nameserver: [127.0.0.1:9]
tun:
  enable: true
  stack: mips
  dns-hijack: ['any:53']
  route-address: ['192.0.2.53/32']
  auto-route: true
  auto-detect-interface: true
rules:
  - MATCH,DIRECT
YAML

hash="$(shasum -a 256 "$core" | awk '{ print $1 }')"
installed="true"
sudo -n "$tools/tunnelmaster-service-install" --install-service --install-core "$core" --sha256 "$hash"
sudo -n launchctl print "system/$service_id" >/dev/null
sudo -n /bin/test -x "$installed_core"
echo "TunnelMaster helper is registered and can read the executable it staged."

CLASH_VERGE_TEST_SESSION_GENERATION="$("$driver" start-runtime "$scratch/fixture.yaml" "$installed_core")"
[[ "$CLASH_VERGE_TEST_SESSION_GENERATION" =~ ^[0-9]+$ ]]
echo "TunnelMaster helper accepted the production IPC request."

for attempt in {1..30}; do
  fixture_network="$(route_interface "$fixture_address")"
  if [[ "$fixture_network" == utun* && "$fixture_network" != "$initial_fixture_network" ]] &&
    curl --silent --fail --max-time 1 --unix-socket "$ipc" http://localhost/configs -o actual-config.json; then
    break
  fi
  sleep 1
done

test -s actual-config.json
[[ "$fixture_network" == utun* && "$fixture_network" != "$initial_fixture_network" ]]
test "$(route_interface 1.1.1.1)" = "$main_network"
python3 -c 'import json; assert json.load(open("actual-config.json"))["tun"]["enable"] is True'
test "$(dig @"$fixture_address" "$fixture_name." A +short +tries=2 +time=2)" = "$requested_answer"
echo "Privileged helper launched Mihomo. The macOS TUN processed a DNS query over the fixture route."

"$driver" stop
CLASH_VERGE_TEST_SESSION_GENERATION=""
for attempt in {1..30}; do
  if [[ "$(route_interface "$fixture_address")" == "$initial_fixture_network" ]] && [[ ! -S "$ipc" ]]; then
    break
  fi
  sleep 1
done
test "$(route_interface "$fixture_address")" = "$initial_fixture_network"
test "$(route_interface 1.1.1.1)" = "$main_network"
test ! -S "$ipc"
scutil --proxy > proxy-after.txt
cmp proxy-before.txt proxy-after.txt

sudo -n "$tools/tunnelmaster-service-uninstall"
installed="false"
if sudo -n launchctl print "system/$service_id" >/dev/null 2>&1; then
  echo "TunnelMaster helper is still registered after uninstall." >&2
  exit 1
fi
echo "Stopping and uninstalling TunnelMaster restored the fixture route and preserved the default route and system proxy."
