#!/usr/bin/env bash
# Boot a throwaway Rocky Linux 9 VM with QEMU (KVM if available, software
# emulation otherwise) and wait until it accepts SSH on 127.0.0.1:2222.
set -euo pipefail

IMAGE_BASE=https://dl.rockylinux.org/pub/rocky/9/images/x86_64
IMAGE=Rocky-9-GenericCloud-Base.latest.x86_64.qcow2
WORKDIR=${VM_WORKDIR:-/tmp/rocky-vm}
PUBKEY=${VM_PUBKEY:-$HOME/.ssh/id_ed25519.pub}
BOOT_TIMEOUT=${VM_BOOT_TIMEOUT:-1800}

mkdir -p "$WORKDIR"
cd "$WORKDIR"

curl -fsSL -o base.qcow2 "$IMAGE_BASE/$IMAGE"
expected=$(curl -fsSL "$IMAGE_BASE/CHECKSUM" | awk -v img="($IMAGE)" '$2 == img {print $NF}')
echo "$expected  base.qcow2" | sha256sum -c -

qemu-img create -q -f qcow2 -F qcow2 -b base.qcow2 disk.qcow2 60G

cat > user-data <<EOF
#cloud-config
users:
  - name: ls
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$PUBKEY")
EOF
printf 'instance-id: ci\nlocal-hostname: rocky-ci\n' > meta-data
genisoimage -quiet -output seed.iso -volid cidata -joliet -rock user-data meta-data

if [ -w /dev/kvm ]; then
  accel=kvm cpu=host
else
  accel=tcg cpu=max
fi
echo "Starting VM with accel=$accel"

qemu-system-x86_64 \
  -machine q35,accel="$accel" -cpu "$cpu" -smp 4 -m 6144 \
  -drive file=disk.qcow2,if=virtio \
  -drive file=seed.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -display none -serial file:serial.log \
  -pidfile qemu.pid -daemonize

deadline=$((SECONDS + BOOT_TIMEOUT))
until ssh -q -p 2222 -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      ls@127.0.0.1 'cloud-init status --wait >/dev/null 2>&1; true'; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "VM did not come up within ${BOOT_TIMEOUT}s, serial log:"
    tail -50 serial.log
    exit 1
  fi
  echo "waiting for SSH on the VM (${SECONDS}s)"
  sleep 10
done
echo "VM is up after ${SECONDS}s"
