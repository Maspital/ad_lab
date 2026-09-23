#!/usr/bin/env bash
# Spike #11 Q4: golden snapshot + change + revert on a UEFI (D19 posture) + swtpm guest,
# on an overlay volume (D21), as the unprivileged controller user against qemu:///system.
#
# The guest is an Ubuntu cloud image; the mechanism is OS-agnostic. Three markers make each
# part of golden state (D3) observable:
#   disk  - a file on the root filesystem       (qcow2 overlay)
#   nvram - a UEFI variable written via efivarfs (OVMF vars, nvram)
#   tpm   - a TPM NV index                       (swtpm state)
# A revert is correct for a layer when that layer's marker reads "golden" again.
#
# Only the libvirt API (virsh) is used; the script never reads or writes /var/lib/libvirt
# itself. It probes that directory once to record what the user can and cannot see.
#
# Usage: q4-snapshot.sh setup|live|offline|cleanup|all
# Env:   RAM_MB (2048), VCPUS (2), SKEW_WAIT (120 s between snapshot and revert),
#        LOADER_FORMAT (raw|qcow2, see below), IMAGE_URL.
set -euo pipefail

CONN=qemu:///system
POOL=adlab-spike
POOL_DIR=/var/lib/libvirt/images/adlab-spike
DOM=adlab-spike-q4
BASE_VOL=q4-base.qcow2
OVL_VOL=q4-overlay.qcow2
SEED_VOL=q4-seed.iso
RAM_MB=${RAM_MB:-2048}
VCPUS=${VCPUS:-2}
SKEW_WAIT=${SKEW_WAIT:-120}
IMAGE_URL=${IMAGE_URL:-https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img}
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd   # Secure-Boot-capable code (D19)
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd           # non-enrolled vars template (D19)
# If libvirt insists the loader format match the qcow2 nvram, LOADER_FORMAT=qcow2 uploads a
# qcow2 conversion of the code into the pool and points the loader at it.
LOADER_FORMAT=${LOADER_FORMAT:-raw}
EFI_GUID=8be4df61-93ca-11d2-aa0d-00e098032b8c        # vendor GUID used for the marker var
TPM_NV=0x1500016

STATE=${XDG_STATE_HOME:-$HOME/.local/state}/adlab-spike/q4
mkdir -p "$STATE"
KEY=$STATE/id_ed25519
RESULTS=$STATE/results.md

v() { virsh -c "$CONN" "$@"; }
now() { date +%s.%N; }
elapsed() { python3 -c "import sys; print(f'{float(sys.argv[2]) - float(sys.argv[1]):.2f}')" "$1" "$2"; }
log() { printf '%s\n' "$*" | tee -a "$RESULTS"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

preflight() {
    [[ $(id -u) -ne 0 ]] || die "run as the unprivileged controller user, not root"
    for c in virsh ssh ssh-keygen cloud-localds curl qemu-img python3; do
        command -v "$c" >/dev/null || die "missing $c"
    done
    v version >/dev/null || die "cannot reach $CONN as $(id -un) (libvirt group?)"
    [[ -r $OVMF_CODE && -r $OVMF_VARS ]] || die "OVMF files missing: $OVMF_CODE $OVMF_VARS"
}

record_env() {
    log "## Run $(date -Is) — RAM ${RAM_MB} MiB, ${VCPUS} vCPU, loader format ${LOADER_FORMAT}"
    log '```'
    { v version; swtpm --version 2>/dev/null || true; id; } | tee -a "$RESULTS"
    for d in /var/lib/libvirt/qemu/nvram /var/lib/libvirt/swtpm; do
        if ls "$d" >/dev/null 2>&1; then echo "user CAN list $d"; else echo "user cannot list $d"; fi
    done | tee -a "$RESULTS"
    log '```'
}

vol_alloc() { v vol-info --pool "$POOL" "$OVL_VOL" --bytes | awk '/^Allocation:/{print $2}'; }
genid() { v dumpxml "$DOM" | grep -o '<genid>[^<]*</genid>' || echo none; }

guest_ip() {
    v domifaddr "$DOM" --source lease 2>/dev/null | awk '/ipv4/{sub(/\/.*/, "", $4); print $4; exit}'
}

gssh() {
    local ip; ip=$(guest_ip)
    [[ -n $ip ]] || return 1
    ssh -i "$KEY" -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "spike@$ip" "$@"
}

wait_ssh() {
    local t0 deadline; t0=$(now); deadline=$((SECONDS + ${1:-600}))
    until gssh true 2>/dev/null; do
        (( SECONDS < deadline )) || die "no SSH after ${1:-600}s"
        sleep 2
    done
    elapsed "$t0" "$(now)"
}

setup() {
    preflight
    [[ -f $KEY ]] || ssh-keygen -q -t ed25519 -N '' -C adlab-spike-q4 -f "$KEY"

    if ! v pool-info "$POOL" >/dev/null 2>&1; then
        v pool-define-as "$POOL" dir --target "$POOL_DIR"
        v pool-build "$POOL"
    fi
    v pool-info "$POOL" | grep -q 'State:.*running' || v pool-start "$POOL"
    v pool-autostart "$POOL" >/dev/null

    local cache=$HOME/.cache/adlab-spike img
    mkdir -p "$cache"; img=$cache/$(basename "$IMAGE_URL")
    [[ -f $img ]] || curl -fL -o "$img" "$IMAGE_URL"
    if ! v vol-info --pool "$POOL" "$BASE_VOL" >/dev/null 2>&1; then
        v vol-create-as "$POOL" "$BASE_VOL" "$(stat -c %s "$img")" --format qcow2
        v vol-upload --pool "$POOL" "$BASE_VOL" "$img"
        v pool-refresh "$POOL"
    fi
    v vol-info --pool "$POOL" "$OVL_VOL" >/dev/null 2>&1 ||
        v vol-create-as "$POOL" "$OVL_VOL" 20G --format qcow2 \
            --backing-vol "$BASE_VOL" --backing-vol-format qcow2

    local loader=$OVMF_CODE
    if [[ $LOADER_FORMAT == qcow2 ]]; then
        qemu-img convert -f raw -O qcow2 "$OVMF_CODE" "$STATE/code.qcow2"
        v vol-info --pool "$POOL" q4-code.qcow2 >/dev/null 2>&1 || {
            v vol-create-as "$POOL" q4-code.qcow2 "$(stat -c %s "$STATE/code.qcow2")" --format qcow2
            v vol-upload --pool "$POOL" q4-code.qcow2 "$STATE/code.qcow2"
        }
        loader=$POOL_DIR/q4-code.qcow2
    fi

    cat >"$STATE/user-data" <<EOF
#cloud-config
users:
  - name: spike
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: ["$(cat "$KEY.pub")"]
packages: [tpm2-tools, qemu-guest-agent]
runcmd: [[systemctl, enable, --now, qemu-guest-agent]]
EOF
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$DOM" "$DOM" >"$STATE/meta-data"
    cloud-localds "$STATE/seed.iso" "$STATE/user-data" "$STATE/meta-data"
    v vol-info --pool "$POOL" "$SEED_VOL" >/dev/null 2>&1 && v vol-delete --pool "$POOL" "$SEED_VOL"
    v vol-create-as "$POOL" "$SEED_VOL" "$(stat -c %s "$STATE/seed.iso")" --format raw
    v vol-upload --pool "$POOL" "$SEED_VOL" "$STATE/seed.iso"

    cat >"$STATE/domain.xml" <<EOF
<domain type='kvm'>
  <name>$DOM</name>
  <memory unit='MiB'>$RAM_MB</memory>
  <vcpu>$VCPUS</vcpu>
  <genid/>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' secure='yes' type='pflash' format='$LOADER_FORMAT'>$loader</loader>
    <nvram template='$OVMF_VARS' templateFormat='raw' format='qcow2'/>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/><smm state='on'/></features>
  <cpu mode='host-passthrough'/>
  <clock offset='utc'/>
  <devices>
    <disk type='volume' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source pool='$POOL' volume='$OVL_VOL'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='volume' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source pool='$POOL' volume='$SEED_VOL'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'><source network='default'/><model type='virtio'/></interface>
    <tpm model='tpm-crb'><backend type='emulator' version='2.0'/></tpm>
    <channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>
    <serial type='pty'/><console type='pty'/>
  </devices>
</domain>
EOF
    v dominfo "$DOM" >/dev/null 2>&1 || v define "$STATE/domain.xml"
    v domstate "$DOM" | grep -q running || v start "$DOM"

    record_env
    log "- first boot to SSH: $(wait_ssh 900) s"
    gssh cloud-init status --wait >/dev/null
    gssh 'test -d /sys/firmware/efi && ls /dev/tpmrm0 && mokutil --sb-state 2>/dev/null || true' | tee -a "$RESULTS"
    # The seed CD is raw; eject it so every remaining disk supports internal snapshots.
    v change-media "$DOM" sda --eject --live --config
    gssh sudo tpm2_nvdefine "$TPM_NV" -C o -s 16 -a 'ownerread|ownerwrite' >/dev/null
}

set_markers() {
    gssh sudo bash -s -- "$1" "$EFI_GUID" "$TPM_NV" <<'EOF'
set -e
val=$1 guid=$2 nv=$3
echo "$val" > /var/lib/adlab-marker
f=/sys/firmware/efi/efivars/AdlabMarker-$guid
[ -e "$f" ] && chattr -i "$f" && rm -f "$f"
printf '\007\000\000\000%s' "$val" > "$f"
printf '%-16s' "$val" > /tmp/nv && tpm2_nvwrite "$nv" -C o -i /tmp/nv
sync
EOF
}

read_markers() {
    gssh sudo bash -s -- "$EFI_GUID" "$TPM_NV" <<'EOF'
guid=$1 nv=$2
printf 'disk=%s nvram=%s tpm=%s\n' \
    "$(cat /var/lib/adlab-marker 2>/dev/null || echo missing)" \
    "$(tail -c +5 /sys/firmware/efi/efivars/AdlabMarker-$guid 2>/dev/null || echo missing)" \
    "$(tpm2_nvread "$nv" -C o -s 16 2>/dev/null | tr -d ' \0' || echo unreadable)"
EOF
}

skew() {
    local g; g=$(gssh date +%s.%N)
    elapsed "$g" "$(now)"
}

live() {
    preflight
    log "### Candidate 1, live internal snapshot (memory included), RAM ${RAM_MB} MiB"
    set_markers golden
    log "- markers before snapshot: $(read_markers)"
    local a0 t0 a1; a0=$(vol_alloc); log "- genid before: $(genid)"
    t0=$(now)
    if ! v snapshot-create-as "$DOM" golden-live --description 'spike q4 live' 2>&1 | tee -a "$RESULTS"; then
        log "- **live snapshot-create FAILED** (see error above)"; return 1
    fi
    log "- snapshot-create: $(elapsed "$t0" "$(now)") s"
    a1=$(vol_alloc); log "- overlay allocation: $a0 -> $a1 bytes (+$(( (a1 - a0) / 1048576 )) MiB)"
    v snapshot-dumpxml "$DOM" golden-live | grep -E "<(state|memory|disk) " | tee -a "$RESULTS"

    set_markers changed
    log "- markers after change: $(read_markers)"
    log "- waiting ${SKEW_WAIT}s so the stale-clock effect is measurable"; sleep "$SKEW_WAIT"

    t0=$(now)
    v snapshot-revert "$DOM" --snapshotname golden-live --running 2>&1 | tee -a "$RESULTS"
    log "- snapshot-revert: $(elapsed "$t0" "$(now)") s; SSH back after $(wait_ssh 120) s"
    log "- markers after revert: $(read_markers)"
    log "- genid after: $(genid)"
    log "- guest clock behind host after revert: $(skew) s"
    if v domtime "$DOM" --now 2>&1 | tee -a "$RESULTS"; then
        log "- after qemu-ga guest-set-time: $(skew) s behind"
    fi
}

offline() {
    preflight
    log "### Candidate 1, offline internal snapshot (stopped VM, no vmstate), RAM ${RAM_MB} MiB"
    set_markers golden
    log "- markers before snapshot: $(read_markers)"
    v shutdown "$DOM"; until v domstate "$DOM" | grep -q 'shut off'; do sleep 2; done
    local t0; t0=$(now)
    if ! v snapshot-create-as "$DOM" golden-off --description 'spike q4 offline' 2>&1 | tee -a "$RESULTS"; then
        log "- **offline snapshot-create FAILED** (see error above)"; return 1
    fi
    log "- snapshot-create (stopped): $(elapsed "$t0" "$(now)") s"
    v start "$DOM"; wait_ssh 300 >/dev/null
    set_markers changed
    log "- markers after change: $(read_markers)"
    v shutdown "$DOM"; until v domstate "$DOM" | grep -q 'shut off'; do sleep 2; done
    t0=$(now)
    v snapshot-revert "$DOM" --snapshotname golden-off 2>&1 | tee -a "$RESULTS"
    log "- snapshot-revert (stopped): $(elapsed "$t0" "$(now)") s"
    v start "$DOM"; log "- boot after revert to SSH: $(wait_ssh 300) s"
    log "- markers after revert: $(read_markers)"
    log "- genid after: $(genid)"
    log "- guest clock behind host after revert: $(skew) s"
}

cleanup() {
    local s
    if v dominfo "$DOM" >/dev/null 2>&1; then
        v destroy "$DOM" 2>/dev/null || true
        for s in $(v snapshot-list "$DOM" --name 2>/dev/null); do
            v snapshot-delete "$DOM" --snapshotname "$s"
        done
        v undefine "$DOM" --nvram --tpm
    fi
    for s in "$OVL_VOL" "$SEED_VOL" q4-code.qcow2; do
        v vol-info --pool "$POOL" "$s" >/dev/null 2>&1 && v vol-delete --pool "$POOL" "$s"
    done
    echo "kept: pool $POOL with $BASE_VOL, results in $RESULTS"
}

case ${1:-} in
    setup) setup ;;
    live) live ;;
    offline) offline ;;
    cleanup) cleanup ;;
    all) setup; live; offline ;;
    *) echo "usage: $0 setup|live|offline|cleanup|all" >&2; exit 2 ;;
esac
