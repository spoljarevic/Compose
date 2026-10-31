#!/usr/bin/env bash
# Runs inside the test VM as a normal user: start every stack with rootless
# podman-compose on its own, wait until its containers run (and are healthy
# where they have a healthcheck), check that nothing restarts for a while and
# that every published TCP port answers, then tear it down again.
# Usage: test-compose.sh [stack ...]   (default: every dir with a podman-compose.yml)
set -uo pipefail

REPO=$HOME/Compose
START_TIMEOUT=${START_TIMEOUT:-1200}
STABLE_SECONDS=${STABLE_SECONDS:-60}
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus

if [ "$#" -gt 0 ]; then
  stacks=("$@")
else
  mapfile -t stacks < <(cd "$REPO" && find . -mindepth 2 -maxdepth 2 -name podman-compose.yml -printf '%h\n' | sed 's#^\./##' | sort)
fi

prepare_host() {
  # podman-compose from pip: EPEL's package pulls in iptables-legacy, which
  # breaks the networks of rootless containers
  sudo dnf -y -q install podman python3 python3-pip python3-pyyaml >/dev/null
  pip3 install -q --user podman-compose
  export PATH=$HOME/.local/bin:$PATH
  podman --version; podman-compose --version | tail -1
  sudo loginctl enable-linger "$USER"
  systemctl --user start dbus.socket
  # nginx-proxy-manager publishes 80/443, which rootless podman may only bind with this
  sudo sysctl -q -w net.ipv4.ip_unprivileged_port_start=80
}

# Host paths and published ports of the interpolated compose file
compose_info() {
  podman-compose -f podman-compose.yml config 2>/dev/null | python3 -c '
import sys, yaml
cfg = yaml.safe_load(sys.stdin)
for svc in (cfg.get("services") or {}).values():
    for vol in svc.get("volumes") or []:
        src = vol.get("source") if isinstance(vol, dict) else str(vol).split(":")[0]
        if src and src.startswith(("/", "./")):
            print("dir", src)
    for port in svc.get("ports") or []:
        p = port.get("published") if isinstance(port, dict) else str(port)
        if isinstance(port, dict):
            if port.get("protocol", "tcp") == "tcp" and p:
                print("port", p)
        else:
            parts = p.split("/")[0].split(":")
            if len(parts) >= 2 and not p.endswith("/udp"):
                print("port", parts[-2])
'
}

containers_ok() {
  local name state exit health policy bad=0
  while read -r name state exit health policy; do
    case "$state" in
      running) [ "$health" = "<no value>" ] || [ -z "$health" ] || [ "$health" = healthy ] || bad=1 ;;
      exited) [ "$exit" = 0 ] && [ "$policy" != always ] && [ "$policy" != unless-stopped ] || bad=1 ;;
      *) bad=1 ;;
    esac
  done < <(podman ps -a --filter "label=io.podman.compose.project=$1" --format '{{.Names}}' | while read -r c; do
             podman inspect "$c" --format '{{.Name}} {{.State.Status}} {{.State.ExitCode}} {{.State.Health.Status}} {{.HostConfig.RestartPolicy.Name}}'
           done)
  [ "$bad" = 0 ] && [ -n "$(podman ps -a -q --filter "label=io.podman.compose.project=$1")" ]
}

restart_counts() {
  podman ps -a --filter "label=io.podman.compose.project=$1" --format '{{.Names}}' | sort | while read -r c; do
    echo "$c $(podman inspect "$c" --format '{{.RestartCount}}')"
  done
}

test_stack() {
  local stack=$1 project deadline before port
  echo
  echo "######## $stack"
  cd "$REPO/$stack" || return 1
  project=$(basename "$stack")
  [ -e env.example ] && [ ! -e .env ] && cp env.example .env
  while read -r kind value; do
    [ "$kind" = dir ] && { mkdir -p "$value" 2>/dev/null || sudo install -d -o "$USER" "$value"; }
  done < <(compose_info)

  if ! podman-compose -f podman-compose.yml up -d > /tmp/up.log 2>&1; then
    echo "FAIL: podman-compose up failed"; tail -20 /tmp/up.log; return 1
  fi
  deadline=$((SECONDS + START_TIMEOUT))
  until containers_ok "$project"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "FAIL: containers not running/healthy after ${START_TIMEOUT}s"
      podman ps -a --filter "label=io.podman.compose.project=$project"
      for c in $(podman ps -a --filter "label=io.podman.compose.project=$project" --format '{{.Names}}'); do
        echo "== $c"; podman logs --tail 15 "$c" 2>&1
      done
      return 1
    fi
    sleep 10
  done
  echo "all containers up after ${SECONDS}s"

  before=$(restart_counts "$project")
  sleep "$STABLE_SECONDS"
  if [ "$(restart_counts "$project")" != "$before" ] || ! containers_ok "$project"; then
    echo "FAIL: containers restarted within ${STABLE_SECONDS}s"
    podman ps -a --filter "label=io.podman.compose.project=$project"
    return 1
  fi
  echo "no restarts within ${STABLE_SECONDS}s"

  while read -r kind port; do
    [ "$kind" = port ] || continue
    deadline=$((SECONDS + START_TIMEOUT))
    until timeout 5 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; do
      if [ "$SECONDS" -ge "$deadline" ]; then echo "FAIL: nothing answers on published port $port"; return 1; fi
      sleep 10
    done
    echo "port $port answers"
  done < <(compose_info)
  return 0
}

cleanup_stack() {
  (cd "$REPO/$1" && podman-compose -f podman-compose.yml down -v >/dev/null 2>&1)
  podman system prune -af --volumes >/dev/null 2>&1
}

prepare_host
declare -A result
failed=0
for stack in "${stacks[@]}"; do
  if test_stack "$stack"; then result[$stack]=ok; else result[$stack]=FAILED; failed=1; fi
  cleanup_stack "$stack"
done

echo
echo "######## Summary"
for stack in "${stacks[@]}"; do printf '%-24s %s\n' "$stack" "${result[$stack]}"; done
exit "$failed"
