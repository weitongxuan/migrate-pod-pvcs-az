#!/usr/bin/env bash
set -euo pipefail

# Migrate all gp2 EBS-backed PVCs used by a given Pod to another AZ.
# Auto scale-down/up Deployments/StatefulSets that reference those PVCs.
#
# Usage:
#   ./migrate-pod-pvcs-gp2-az-autoscale.sh \
#     -n <namespace> -P <pod_name> -z <target_az> -r <region> [-c <kube_context>] [--dry-run]
#
# Requirements: aws cli v2, kubectl, jq

NS="" ; POD="" ; TARGET_AZ="" ; REGION="" ; KCTX="" ; DRY_RUN=0
log(){ echo "[$(date +'%F %T')] $*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NS="$2"; shift 2;;
    -P|--pod) POD="$2"; shift 2;;
    -z|--target-az) TARGET_AZ="$2"; shift 2;;
    -r|--region) REGION="$2"; shift 2;;
    -c|--context) KCTX="--context $2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) grep -E '^# ' "$0" | sed 's/^# //'; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -z "$NS" || -z "$POD" || -z "$TARGET_AZ" || -z "$REGION" ]] && die "Missing required args. Use -h."

command -v aws >/dev/null || die "aws cli not found"
command -v kubectl >/dev/null || die "kubectl not found"
command -v jq >/dev/null || die "jq not found"

K="kubectl $KCTX -n $NS"

log "Namespace: $NS ; Pod: $POD ; Region: $REGION ; Target AZ: $TARGET_AZ"
[[ $DRY_RUN -eq 1 ]] && log "DRY-RUN mode enabled (no changes will be made)."

# ---------------- Discover PVCs from the Pod ----------------
pod_json=$($K get pod "$POD" -o json) || die "Pod $POD not found in $NS."
mapfile -t PVC_LIST < <(jq -r '.spec.volumes[]? | select(.persistentVolumeClaim!=null) | .persistentVolumeClaim.claimName' <<<"$pod_json" | sort -u)
[[ ${#PVC_LIST[@]} -eq 0 ]] && die "No PVCs found on Pod $POD."
log "Found PVCs: ${PVC_LIST[*]}"

PVC_JSON_ARRAY=$(printf '%s\n' "${PVC_LIST[@]}" | jq -R . | jq -s .)

# ---------------- Find Deployments/StatefulSets that reference these PVCs ----------------
NS_ALL_JSON=$(kubectl $KCTX -n "$NS" get deploy,statefulset -o json)
mapfile -t CTLS < <(jq -r --argjson targets "$PVC_JSON_ARRAY" '
  .items[]
  | . as $obj
  | ( [ $obj.spec.template.spec.volumes[]? | select(.persistentVolumeClaim?!=null) | .persistentVolumeClaim.claimName ] ) as $template_pvcs
  | ( if ($obj.kind == "StatefulSet") then
        [ $obj.spec.volumeClaimTemplates[]?.metadata.name as $tpl | $targets[] | select(startswith($tpl + "-" + $obj.metadata.name + "-")) | . ] 
      else [] end ) as $stateful_pvcs
  | ($template_pvcs + $stateful_pvcs) as $all_pvcs
  | ($all_pvcs | map( . as $x | ($targets | index($x)) ) | any) as $uses
  | select($uses)
  | [(.kind), (.metadata.name), ((.spec.replicas // 1)|tostring)]
  | @tsv
' <<<"$NS_ALL_JSON")

declare -a CTL_KIND CTL_NAME CTL_REPLICAS
for line in "${CTLS[@]:-}"; do
  IFS=$'\t' read -r k n r <<<"$line"
  CTL_KIND+=("$k"); CTL_NAME+=("$n"); CTL_REPLICAS+=("$r")
done

if [[ ${#CTL_KIND[@]} -eq 0 ]]; then
  log "No Deployment/StatefulSet in $NS referencing these PVCs. Will proceed without autoscaling."
fi

SCALED=0

scale_down(){
  [[ ${#CTL_KIND[@]} -eq 0 ]] && return 0
  for i in "${!CTL_KIND[@]}"; do
    local kind="${CTL_KIND[$i]}" name="${CTL_NAME[$i]}" replicas="${CTL_REPLICAS[$i]}"
    log "Scaling down ${kind}/${name} from replicas=${replicas} -> 0 ..."
    if [[ $DRY_RUN -eq 0 ]]; then
      kubectl $KCTX -n "$NS" scale "$kind" "$name" --replicas=0
    else
      log "[DRY-RUN] Would scale $kind/$name to 0"
    fi
  done

  if [[ $DRY_RUN -eq 0 ]]; then
    log "Waiting for pods using target PVCs to terminate..."
    for t in {1..60}; do
      inuse=$($K get pods -o json \
        | jq --argjson targets "$PVC_JSON_ARRAY" -r '
            [.items[]?
              | {phase: .status.phase,
                 pvcs: ([.spec.volumes[]? | select(.persistentVolumeClaim?!=null) | .persistentVolumeClaim.claimName] // [])}
              | select( (.pvcs | map( . as $x | ($targets | index($x)) ) | any)
                        and (.phase!="Succeeded") )
            ] | length')
      [[ "$inuse" == "0" ]] && { log "All related pods terminated."; break; }
      sleep 5
      [[ $t -eq 60 ]] && die "Timeout waiting for pods to terminate."
    done
  fi
  SCALED=1
}

restore(){
  [[ $SCALED -eq 1 ]] || return 0
  for i in "${!CTL_KIND[@]}"; do
    local kind="${CTL_KIND[$i]}" name="${CTL_NAME[$i]}" replicas="${CTL_REPLICAS[$i]}"
    log "Restoring ${kind}/${name} -> replicas=${replicas} ..."
    if [[ $DRY_RUN -eq 0 ]]; then
      kubectl $KCTX -n "$NS" scale "$kind" "$name" --replicas="$replicas" || log "WARN: restore scale failed for $kind/$name"
    else
      log "[DRY-RUN] Would restore $kind/$name to $replicas"
    fi
  done
}

trap 'rc=$?; if [[ $rc -ne 0 ]]; then log "Script error (rc=$rc). Attempting to restore controllers..."; fi; restore; exit $rc' EXIT

# ---------------- Migrate one PVC if its EBS VolumeType is gp2 ----------------
migrate_one_pvc(){
  local pvc="$1"
  log "---- Processing PVC: $pvc ----"

  local pvc_json pv_name pv_json sc capacity csi_driver fs_type vol_id
  pvc_json=$($K get pvc "$pvc" -o json) || { log "Skip: PVC $pvc not found"; return 0; }
  pv_name=$(jq -r '.spec.volumeName' <<<"$pvc_json")
  [[ -z "$pv_name" || "$pv_name" == "null" ]] && { log "Skip: PVC $pvc not bound yet."; return 0; }

  pv_json=$(kubectl $KCTX get pv "$pv_name" -o json)
  sc=$(jq -r '.spec.storageClassName' <<<"$pv_json")
  capacity=$(jq -r '.spec.capacity.storage' <<<"$pv_json")
  csi_driver=$(jq -r '.spec.csi.driver? // empty' <<<"$pv_json")

  if [[ -n "$csi_driver" ]]; then
    [[ "$csi_driver" != "ebs.csi.aws.com" ]] && { log "Skip: PV $pv_name driver=$csi_driver (not ebs.csi.aws.com)."; return 0; }
    vol_id=$(jq -r '.spec.csi.volumeHandle' <<<"$pv_json")
    fs_type=$(jq -r '.spec.csi.fsType // "ext4"' <<<"$pv_json")
  else
    local awsebs
    awsebs=$(jq -r '.spec.awsElasticBlockStore.volumeID // empty' <<<"$pv_json")
    [[ -z "$awsebs" || "$awsebs" == "null" ]] && { log "Skip: PV $pv_name not EBS-backed."; return 0; }
    vol_id="${awsebs##*/}"
    fs_type=$(jq -r '.spec.awsElasticBlockStore.fsType // "ext4"' <<<"$pv_json")
  fi

  local vj vol_type src_az encrypted kms size_gb iops throughput
  vj=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$vol_id" --output json)
  vol_type=$(jq -r '.Volumes[0].VolumeType' <<<"$vj")
  src_az=$(jq -r '.Volumes[0].AvailabilityZone' <<<"$vj")
  encrypted=$(jq -r '.Volumes[0].Encrypted' <<<"$vj")
  kms=$(jq -r '.Volumes[0].KmsKeyId // empty' <<<"$vj")
  size_gb=$(jq -r '.Volumes[0].Size' <<<"$vj")
  iops=$(jq -r '.Volumes[0].Iops // empty' <<<"$vj")
  throughput=$(jq -r '.Volumes[0].Throughput // empty' <<<"$vj")

  if [[ "$vol_type" != "gp2" ]]; then
    log "Skip: PVC $pvc -> Volume $vol_id is type '$vol_type' (only gp2)."
    return 0
  fi
  if [[ "$src_az" == "$TARGET_AZ" ]]; then
    log "Skip: PVC $pvc already in target AZ ($TARGET_AZ)."
    return 0
  fi

  log "Candidate: PVC=$pvc PV=$pv_name SC=$sc cap=$capacity ; Volume=$vol_id type=$vol_type ${src_az} -> ${TARGET_AZ}"

  local stamp snap_desc snap_id new_vol_id
  stamp=$(date +%Y%m%d%H%M%S)
  snap_desc="migrate-gp2-${NS}-${pvc}-${stamp}"

  if [[ $DRY_RUN -eq 0 ]]; then
    snap_id=$(aws ec2 create-snapshot --region "$REGION" --volume-id "$vol_id" \
      --description "$snap_desc" \
      --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=${snap_desc}},{Key=PVC,Value=${pvc}},{Key=Namespace,Value=${NS}}]" \
      --query SnapshotId --output text)
    log "Snapshot $snap_id created; waiting to complete..."
    aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$snap_id"
  else
    snap_id="snap-DRYRUN"; log "[DRY-RUN] Would create snapshot of $vol_id"
  fi

  if [[ $DRY_RUN -eq 0 ]]; then
    args=(--region "$REGION" --availability-zone "$TARGET_AZ" --snapshot-id "$snap_id" --volume-type "$vol_type" --size "$size_gb")
    # Only add IOPS for volume types that support it (gp3, io1, io2)
    if [[ "$vol_type" =~ ^(gp3|io1|io2)$ && -n "$iops" && "$iops" != "null" ]]; then
      args+=(--iops "$iops")
    fi
    # Only add throughput for volume types that support it (gp3)
    if [[ "$vol_type" == "gp3" && -n "$throughput" && "$throughput" != "null" ]]; then
      args+=(--throughput "$throughput")
    fi
    [[ "$encrypted" == "true" ]] && args+=(--encrypted)
    [[ -n "$kms" ]] && args+=(--kms-key-id "$kms")
    new_vol_id=$(aws ec2 create-volume "${args[@]}" \
      --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${snap_desc}-dst},{Key=PVC,Value=${pvc}},{Key=Namespace,Value=${NS}}]" \
      --query VolumeId --output text)
    log "Created new volume: $new_vol_id ; waiting available..."
    aws ec2 wait volume-available --region "$REGION" --volume-ids "$new_vol_id"
  else
    new_vol_id="vol-DRYRUN"; log "[DRY-RUN] Would create new volume in $TARGET_AZ from $snap_id"
  fi

  # ---- Compose driver block safely (no nested heredocs) ----
  local DRIVER_YAML
  if [[ -n "$csi_driver" ]]; then
    DRIVER_YAML=$(cat <<EOF
  csi:
    driver: ebs.csi.aws.com
    fsType: ${fs_type}
    volumeHandle: ${new_vol_id}
EOF
)
  else
    DRIVER_YAML=$(cat <<EOF
  awsElasticBlockStore:
    fsType: ${fs_type}
    volumeID: aws://${TARGET_AZ}/${new_vol_id}
EOF
)
  fi

  # Safety: set original PV to Retain
  if [[ $DRY_RUN -eq 0 ]]; then
    kubectl $KCTX patch pv "$pv_name" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null || true
  else
    log "[DRY-RUN] Would patch PV $pv_name reclaimPolicy->Retain"
  fi

  local new_pv_name="${pv_name}-migrated-${stamp}"
  local tmp_dir; tmp_dir="$(mktemp -d)"
  local new_pv_yaml="${tmp_dir}/pv-${new_pv_name}.yaml"
  local new_pvc_yaml="${tmp_dir}/pvc-${pvc}.yaml"
  local orig_pvc_yaml="${tmp_dir}/pvc-orig-${pvc}.yaml"

  # Build PV manifest
  cat > "$new_pv_yaml" <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${new_pv_name}
spec:
  capacity:
    storage: ${capacity}
  accessModes: $(jq -r '.spec.accessModes' <<<"$pv_json")
  storageClassName: ${sc}
  persistentVolumeReclaimPolicy: $(jq -r '.spec.persistentVolumeReclaimPolicy // "Delete"' <<<"$pv_json")
  claimRef:
    namespace: ${NS}
    name: ${pvc}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: topology.kubernetes.io/zone
          operator: In
          values:
          - ${TARGET_AZ}
${DRIVER_YAML}
EOF

  # Backup & reapply PVC (remove binding fields)
  jq --arg ns "$NS" '
    del(.metadata.annotations["pv.kubernetes.io/bind-completed","pv.kubernetes.io/bound-by-controller"]) |
    del(.spec.volumeName) |
    .metadata.namespace = $ns |
    .metadata |= {name: .name, namespace: .namespace} |
    .metadata.labels = (.metadata.labels // {}) |
    .metadata.annotations = (.metadata.annotations // {})
  ' <<<"$pvc_json" > "$orig_pvc_yaml"
  cp "$orig_pvc_yaml" "$new_pvc_yaml"

  log "PV manifest: $new_pv_yaml"
  log "PVC backup:  $orig_pvc_yaml"

  if [[ $DRY_RUN -eq 0 ]]; then
    kubectl $KCTX apply -f "$new_pv_yaml"
    $K delete pvc "$pvc"
    kubectl $KCTX apply -f "$new_pvc_yaml"

    log "Waiting for PVC to bind to ${new_pv_name}..."
    for i in {1..60}; do
      cur_pv=$($K get pvc "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
      [[ "$cur_pv" == "$new_pv_name" ]] && { log "PVC $pvc bound to ${new_pv_name}."; break; }
      sleep 5
    done
    [[ "$cur_pv" != "$new_pv_name" ]] && die "PVC $pvc did not bind to ${new_pv_name} in time."
    log "PVC $pvc migrated to volume $new_vol_id in AZ $TARGET_AZ."
  else
    log "[DRY-RUN] Would: apply new PV, delete+recreate PVC, wait for binding."
  fi
}

# ---------------- Info & run ----------------
log "This will SCALE DOWN related Deployments/StatefulSets that use these PVCs, then restore afterwards."
[[ $DRY_RUN -eq 1 ]] && log "DRY-RUN: scaling and AWS/K8s ops are simulated."

# Scale down first
scale_down

# Migrate each PVC (only gp2)
for pvc in "${PVC_LIST[@]}"; do
  migrate_one_pvc "$pvc"
done

# Success path: restore and clear trap
restore
trap - EXIT
log "All done. Controllers restored to original replicas."
log "Reminder: ensure scheduling to target AZ ${TARGET_AZ} (nodegroups/affinity/topology)."
