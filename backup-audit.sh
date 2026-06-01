#!/bin/bash

# AWS Comprehensive Backup Audit Script v4.3 (Fixed)
# Fixes over v4.1:
#   - Replaced [[ -v ARRAY[key] ]] (bash 4.3+) with ${ARRAY[key]+isset} (bash 4.0+)
#   - Safe ${#ARRAY[@]} on empty associative arrays under set -u (bash <4.4 compat)
#   - Removed dead for-loop in S3 section (check_region unused)
#   - Auto-discovers regions with active resources (no more silent empty scans)
# Safety: ALL AWS API calls are read-only (describe/list/get only, no mutations)
# UI: Monochromatic Dark Mode Layout for Professional Reporting

set -euo pipefail

# ==================== UI FORMATTING ====================
BOLD='\033[1m'
DIM='\033[2m'
REVERSE='\033[7m'
NC='\033[0m'

# ==================== COUNTERS ====================
TOTAL_RESOURCES=0
BACKED_UP=0
NOT_BACKED_UP=0
BACKUP_PROTECTED_COUNT=0
DLM_TAG_COUNT=0

declare -A AWS_BACKUP_PROTECTED_RESOURCES
declare -A DLM_PROTECTED_TAGS

# ==================== REGION SETUP ====================
# Priority:
#   1. AWS_REGIONS="us-east-1 us-west-2"  — explicit list
#   2. AWS_REGIONS=ALL                     — every enabled region (slow but thorough)
#   3. (default)                           — auto-discover regions that have EC2/RDS/S3 activity
if [ -n "${AWS_REGIONS:-}" ]; then
    if [ "${AWS_REGIONS}" = "ALL" ]; then
        echo -e "${DIM}Discovering all enabled regions...${NC}"
        IFS=$'\n' read -ra REGIONS <<< "$(aws ec2 describe-regions --query 'Regions[*].RegionName' --output text 2>/dev/null | tr '\t' '\n' | sort)"
    else
        IFS=' ' read -ra REGIONS <<< "$AWS_REGIONS"
    fi
else
    echo -e "${DIM}Auto-detecting regions with active resources...${NC}"
    # Fast discovery: check which regions have EC2 instances or RDS databases
    ALL_ENABLED=$(aws ec2 describe-regions --query 'Regions[*].RegionName' --output text 2>/dev/null | tr '\t' '\n' | sort)
    ACTIVE_REGIONS=()
    for r in $ALL_ENABLED; do
        has_resources=false
        # Quick check: any EC2 instances?
        ec2_count=$(aws ec2 describe-instances --region "$r" --query 'length(Reservations[])' --output text 2>/dev/null || echo "0")
        [ "$ec2_count" -gt 0 ] 2>/dev/null && has_resources=true
        # Quick check: any RDS instances?
        if [ "$has_resources" = false ]; then
            rds_count=$(aws rds describe-db-instances --region "$r" --query 'length(DBInstances[])' --output text 2>/dev/null || echo "0")
            [ "$rds_count" -gt 0 ] 2>/dev/null && has_resources=true
        fi
        # Quick check: any Lambda functions?
        if [ "$has_resources" = false ]; then
            lambda_count=$(aws lambda list-functions --region "$r" --query 'length(Functions[])' --output text 2>/dev/null || echo "0")
            [ "$lambda_count" -gt 0 ] 2>/dev/null && has_resources=true
        fi
        if [ "$has_resources" = true ]; then
            ACTIVE_REGIONS+=("$r")
            echo -e "  ${DIM}Found resources in: ${r}${NC}"
        fi
    done
    if [ ${#ACTIVE_REGIONS[@]} -gt 0 ]; then
        REGIONS=("${ACTIVE_REGIONS[@]}")
    else
        # Fallback to CLI default if nothing found
        DEFAULT_REGION=${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}
        REGIONS=("$DEFAULT_REGION")
        echo -e "  ${DIM}No active regions detected, falling back to: ${DEFAULT_REGION}${NC}"
    fi
    echo ""
fi

echo -e "${BOLD}┌────────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│  AWS COMPREHENSIVE BACKUP COVERAGE AUDIT REPORT v4.3               │${NC}"
echo -e "${BOLD}│  $(date '+%Y-%m-%d %H:%M:%S %Z')                                         │${NC}"
echo -e "${BOLD}└────────────────────────────────────────────────────────────────────┘${NC}"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
echo -e "${DIM}Account ID:${NC} ${BOLD}${ACCOUNT_ID}${NC}"
echo -e "${DIM}Regions:${NC}    ${BOLD}${REGIONS[*]}${NC}"
echo ""

# ==================== HELPER FUNCTIONS ====================

get_days_ago() {
    local date_str=$1
    local target_epoch=0
    local current_epoch
    current_epoch=$(date +%s)

    if date --version >/dev/null 2>&1; then
        target_epoch=$(date -d "$date_str" +%s 2>/dev/null || echo "0")
    else
        target_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${date_str:0:19}" +%s 2>/dev/null || echo "0")
    fi

    if [ "$target_epoch" != "0" ]; then
        echo $(( (current_epoch - target_epoch) / 86400 ))
    else
        echo "?"
    fi
}

# Portable associative-array key check (bash 4.0+, safe under set -u)
# ${ARRAY[key]+isset} returns "isset" if the key exists, empty string if not.
check_aws_backup_coverage() {
    [[ -n "${AWS_BACKUP_PROTECTED_RESOURCES[$1]+isset}" ]]
}

check_dlm_coverage() {
    local resource_id=$1
    local region=$2
    local tags
    tags=$(aws ec2 describe-tags --region "$region" \
        --filters "Name=resource-id,Values=${resource_id}" \
        --query 'Tags[].[Key,Value]' --output text 2>/dev/null || echo "")

    if [ -n "$tags" ]; then
        while IFS=$'\t' read -r key value; do
            [[ -n "${DLM_PROTECTED_TAGS[${key}=${value}]+isset}" ]] && return 0
        done <<< "$tags"
    fi
    return 1
}

print_result() {
    local status=$1
    local id=$2
    local extra=$3
    local methods=$4

    if [ "$status" = "OK" ]; then
        BACKED_UP=$((BACKED_UP + 1))
        echo -e "  [OK]   $id $extra - ${methods}"
    elif [ "$status" = "WARN" ]; then
        NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
        echo -e "  [WARN] $id $extra - ${methods}"
    else
        NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
        echo -e "  [FAIL] $id $extra - NO BACKUPS"
    fi
}

# ==================== PHASE 1 & 2: BULK DISCOVERY ====================
echo -e "${REVERSE} PHASE 1 & 2: BULK DISCOVERY & CACHING ${NC}"

total_dlm_policies=0

for REGION in "${REGIONS[@]}"; do
    echo -e "${DIM}Caching data for region: ${REGION}...${NC}"

    # 1. Cache AWS Backup recovery-point ARNs (read-only: list-backup-vaults, list-recovery-points)
    backup_vaults=$(aws backup list-backup-vaults --region "$REGION" \
        --query 'BackupVaultList[*].BackupVaultName' --output text 2>/dev/null || echo "")
    if [ -n "$backup_vaults" ]; then
        for vault in $backup_vaults; do
            while read -r arn; do
                if [ -n "$arn" ]; then
                    AWS_BACKUP_PROTECTED_RESOURCES["$arn"]=1
                    BACKUP_PROTECTED_COUNT=$((BACKUP_PROTECTED_COUNT + 1))
                fi
            done < <(aws backup list-recovery-points-by-backup-vault \
                --backup-vault-name "$vault" --region "$REGION" \
                --query 'RecoveryPoints[?Status==`COMPLETED`].[ResourceArn]' \
                --output text 2>/dev/null || echo "")
        done
    fi

    # 2. Cache DLM target tags (read-only: get-lifecycle-policies, get-lifecycle-policy)
    dlm_policies=$(aws dlm get-lifecycle-policies --region "$REGION" \
        --query 'Policies[?State==`ENABLED`]' --output json 2>/dev/null || echo "[]")
    dlm_policy_count=$(echo "$dlm_policies" | jq 'length')
    total_dlm_policies=$((total_dlm_policies + dlm_policy_count))

    if [ "$dlm_policy_count" -gt 0 ]; then
        while read -r policy_id; do
            target_tags=$(aws dlm get-lifecycle-policy --policy-id "$policy_id" \
                --region "$REGION" 2>/dev/null \
                | jq -r '.Policy.PolicyDetails.TargetTags[]? | "\(.Key)=\(.Value)"' || echo "")
            if [ -n "$target_tags" ]; then
                while read -r tag; do
                    if [ -n "$tag" ]; then
                        DLM_PROTECTED_TAGS["$tag"]=1
                        DLM_TAG_COUNT=$((DLM_TAG_COUNT + 1))
                    fi
                done <<< "$target_tags"
            fi
        done < <(echo "$dlm_policies" | jq -r '.[] | .PolicyId')
    fi

    # 3. Cache EBS snapshots locally to prevent API throttling (read-only: describe-snapshots)
    aws ec2 describe-snapshots --owner-ids self --region "$REGION" \
        --query 'Snapshots[*].[VolumeId,SnapshotId,StartTime]' \
        --output text > "/tmp/aws_ebs_snaps_${REGION}.tmp" 2>/dev/null || true
done

# Safe summary — uses integer counters instead of ${#ARRAY[@]} which is
# unreliable on empty associative arrays under set -u in bash <4.4.
echo -e "[✓] Cached ${BOLD}${BACKUP_PROTECTED_COUNT}${NC} AWS Backup protected resources."
echo -e "[✓] Cached ${BOLD}${total_dlm_policies}${NC} active DLM policies."
echo ""

# ==================== PHASE 3: RESOURCE AUDIT ====================
echo -e "${REVERSE} PHASE 3: RESOURCE AUDIT ${NC}"
echo ""

# --- RDS & AURORA ---
echo -e "${BOLD}RDS Instances & Aurora Clusters${NC}"
echo -e "${DIM}────────────────────────────────────────────────────────────────────${NC}"
for REGION in "${REGIONS[@]}"; do
    # read-only: describe-db-instances
    while IFS=$'\t' read -r db_id db_arn engine retention; do
        [ -z "$db_id" ] && continue
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        methods=()
        [ "$retention" -gt 0 ] && methods+=("Native: ${retention}d")
        check_aws_backup_coverage "$db_arn" && methods+=("AWS Backup")

        [ ${#methods[@]} -gt 0 ] && print_result "OK" "$db_id" "(${engine}) [${REGION}]" "${methods[*]}" \
            || print_result "FAIL" "$db_id" "(${engine}) [${REGION}]" ""
    done < <(aws rds describe-db-instances --region "$REGION" \
        --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceArn,Engine,BackupRetentionPeriod]' \
        --output text 2>/dev/null || echo "")

    # read-only: describe-db-clusters
    while IFS=$'\t' read -r db_id db_arn engine retention; do
        [ -z "$db_id" ] && continue
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        methods=()
        [ "$retention" -gt 0 ] && methods+=("Native: ${retention}d")
        check_aws_backup_coverage "$db_arn" && methods+=("AWS Backup")

        [ ${#methods[@]} -gt 0 ] && print_result "OK" "$db_id" "(Aurora Cluster) [${REGION}]" "${methods[*]}" \
            || print_result "FAIL" "$db_id" "(Aurora Cluster) [${REGION}]" ""
    done < <(aws rds describe-db-clusters --region "$REGION" \
        --query 'DBClusters[?starts_with(Engine, `aurora`)].[DBClusterIdentifier,DBClusterArn,Engine,BackupRetentionPeriod]' \
        --output text 2>/dev/null || echo "")
done
echo ""

# --- EC2 & EBS ---
echo -e "${BOLD}EC2 Instances & EBS Volumes${NC}"
echo -e "${DIM}────────────────────────────────────────────────────────────────────${NC}"
for REGION in "${REGIONS[@]}"; do
    # read-only: describe-instances
    while IFS=$'\t' read -r id name state; do
        [ -z "$id" ] && continue
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        methods=()
        check_aws_backup_coverage "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/${id}" && methods+=("AWS Backup")
        check_dlm_coverage "$id" "$REGION" && methods+=("DLM Policy")

        [ ${#methods[@]} -gt 0 ] && print_result "OK" "$id" "(${name:-N/A}) [${REGION}]" "${methods[*]}" \
            || print_result "FAIL" "$id" "(${name:-N/A}) [${REGION}]" ""
    done < <(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name]' \
        --output text 2>/dev/null || echo "")

    # read-only: describe-volumes (+ local snapshot cache lookup)
    while IFS=$'\t' read -r id size state inst; do
        [ -z "$id" ] && continue
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        methods=()
        check_aws_backup_coverage "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:volume/${id}" && methods+=("AWS Backup")
        check_dlm_coverage "$id" "$REGION" && methods+=("DLM Policy")

        latest_snap=$(grep "^${id}" "/tmp/aws_ebs_snaps_${REGION}.tmp" 2>/dev/null | sort -k3 -r | head -n 1 || echo "")
        if [ -n "$latest_snap" ]; then
            days_ago=$(get_days_ago "$(echo "$latest_snap" | awk '{print $3}')")
            methods+=("Snapshot: ${days_ago}d ago")
        fi

        [ ${#methods[@]} -gt 0 ] && print_result "OK" "$id" "(${size}GB) [${REGION}]" "${methods[*]}" \
            || print_result "FAIL" "$id" "(${size}GB) [${REGION}]" ""
    done < <(aws ec2 describe-volumes --region "$REGION" \
        --query 'Volumes[*].[VolumeId,Size,State,Attachments[0].InstanceId]' \
        --output text 2>/dev/null || echo "")
done
echo ""

# --- DYNAMODB ---
echo -e "${BOLD}DynamoDB Tables${NC}"
echo -e "${DIM}────────────────────────────────────────────────────────────────────${NC}"
for REGION in "${REGIONS[@]}"; do
    # read-only: list-tables, describe-table, describe-continuous-backups
    tables=$(aws dynamodb list-tables --region "$REGION" \
        --query 'TableNames[]' --output text 2>/dev/null || echo "")
    for table in $tables; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        methods=()
        table_arn=$(aws dynamodb describe-table --region "$REGION" --table-name "$table" \
            --query 'Table.TableArn' --output text 2>/dev/null || echo "")

        pitr=$(aws dynamodb describe-continuous-backups --region "$REGION" --table-name "$table" \
            --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' \
            --output text 2>/dev/null || echo "DISABLED")
        [ "$pitr" = "ENABLED" ] && methods+=("PITR")
        [ -n "$table_arn" ] && check_aws_backup_coverage "$table_arn" && methods+=("AWS Backup")

        [ ${#methods[@]} -gt 0 ] && print_result "OK" "$table" "[${REGION}]" "${methods[*]}" \
            || print_result "FAIL" "$table" "[${REGION}]" ""
    done
done
echo ""

# --- EFS & FSX ---
echo -e "${BOLD}File Systems (EFS & FSx)${NC}"
echo -e "${DIM}────────────────────────────────────────────────────────────────────${NC}"
for REGION in "${REGIONS[@]}"; do
    # read-only: describe-file-systems, describe-backup-policy
    while IFS=$'\t' read -r id name arn; do
        [ -z "$id" ] && continue
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        methods=()
        policy=$(aws efs describe-backup-policy --region "$REGION" --file-system-id "$id" \
            --query 'BackupPolicy.Status' --output text 2>/dev/null || echo "DISABLED")
        [ "$policy" = "ENABLED" ] && methods+=("EFS Auto Backup")
        check_aws_backup_coverage "$arn" && methods+=("AWS Backup")

        [ ${#methods[@]} -gt 0 ] && print_result "OK" "$id" "(EFS) [${REGION}]" "${methods[*]}" \
            || print_result "FAIL" "$id" "(EFS) [${REGION}]" ""
    done < <(aws efs describe-file-systems --region "$REGION" \
        --query 'FileSystems[*].[FileSystemId,Name,FileSystemArn]' \
        --output text 2>/dev/null || echo "")

    # read-only: fsx describe-file-systems
    while IFS=$'\t' read -r id type arn; do
        [ -z "$id" ] && continue
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        methods=()
        check_aws_backup_coverage "$arn" && methods+=("AWS Backup")

        [ ${#methods[@]} -gt 0 ] && print_result "OK" "$id" "(FSx ${type}) [${REGION}]" "${methods[*]}" \
            || print_result "FAIL" "$id" "(FSx ${type}) [${REGION}]" ""
    done < <(aws fsx describe-file-systems --region "$REGION" \
        --query 'FileSystems[*].[FileSystemId,FileSystemType,ResourceARN]' \
        --output text 2>/dev/null || echo "")
done
echo ""

# --- DOCDB, NEPTUNE, REDSHIFT, CACHE & MEMORYDB ---
echo -e "${BOLD}Specialty Databases & Caching${NC}"
echo -e "${DIM}────────────────────────────────────────────────────────────────────${NC}"
for REGION in "${REGIONS[@]}"; do
    # DocDB & Neptune (read-only: describe-db-clusters)
    for engine in "docdb" "neptune"; do
        while IFS=$'\t' read -r id arn retention; do
            [ -z "$id" ] && continue
            TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
            methods=()
            [ "$retention" -gt 0 ] && methods+=("Native: ${retention}d")
            check_aws_backup_coverage "$arn" && methods+=("AWS Backup")
            [ ${#methods[@]} -gt 0 ] && print_result "OK" "$id" "(${engine}) [${REGION}]" "${methods[*]}" \
                || print_result "FAIL" "$id" "(${engine}) [${REGION}]" ""
        done < <(aws "$engine" describe-db-clusters --region "$REGION" \
            --query "DBClusters[?Engine==\`$engine\`].[DBClusterIdentifier,DBClusterArn,BackupRetentionPeriod]" \
            --output text 2>/dev/null || echo "")
    done

    # Redshift (read-only: describe-clusters)
    while IFS=$'\t' read -r id retention; do
        [ -z "$id" ] && continue
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        methods=()
        [ "$retention" -gt 0 ] && methods+=("Auto snapshot: ${retention}d")
        check_aws_backup_coverage "arn:aws:redshift:${REGION}:${ACCOUNT_ID}:cluster:${id}" && methods+=("AWS Backup")
        [ ${#methods[@]} -gt 0 ] && print_result "OK" "$id" "(Redshift) [${REGION}]" "${methods[*]}" \
            || print_result "FAIL" "$id" "(Redshift) [${REGION}]" ""
    done < <(aws redshift describe-clusters --region "$REGION" \
        --query 'Clusters[*].[ClusterIdentifier,AutomatedSnapshotRetentionPeriod]' \
        --output text 2>/dev/null || echo "")

    # ElastiCache (read-only: describe-replication-groups)
    while IFS=$'\t' read -r id retention arn; do
        [ -z "$id" ] && continue
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        methods=()
        [ "$retention" -gt 0 ] && methods+=("Auto backup: ${retention}d")
        check_aws_backup_coverage "$arn" && methods+=("AWS Backup")
        [ ${#methods[@]} -gt 0 ] && print_result "OK" "$id" "(Redis) [${REGION}]" "${methods[*]}" \
            || print_result "FAIL" "$id" "(Redis) [${REGION}]" ""
    done < <(aws elasticache describe-replication-groups --region "$REGION" \
        --query 'ReplicationGroups[*].[ReplicationGroupId,SnapshotRetentionLimit,ARN]' \
        --output text 2>/dev/null || echo "")

    # MemoryDB (read-only: describe-clusters, describe-snapshots)
    while IFS=$'\t' read -r name retention arn; do
        [ -z "$name" ] && continue
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        methods=()
        [ "$retention" -gt 0 ] && methods+=("Auto snapshot: ${retention}d")
        check_aws_backup_coverage "$arn" && methods+=("AWS Backup")

        snaps=$(aws memorydb describe-snapshots --region "$REGION" --cluster-name "$name" \
            --query 'Snapshots[0]' --output text 2>/dev/null || echo "")
        [ -n "$snaps" ] && [ "$snaps" != "None" ] && methods+=("Snapshots exist")

        [ ${#methods[@]} -gt 0 ] && print_result "OK" "$name" "(MemoryDB) [${REGION}]" "${methods[*]}" \
            || print_result "FAIL" "$name" "(MemoryDB) [${REGION}]" ""
    done < <(aws memorydb describe-clusters --region "$REGION" \
        --query 'Clusters[*].[Name,SnapshotRetentionLimit,ARN]' \
        --output text 2>/dev/null || echo "")
done
echo ""

# --- SERVERLESS (LAMBDA & ECR) ---
echo -e "${BOLD}Lambda Functions & ECR Repositories${NC}"
echo -e "${DIM}────────────────────────────────────────────────────────────────────${NC}"
for REGION in "${REGIONS[@]}"; do
    # read-only: list-functions
    while IFS=$'\t' read -r name arn type; do
        [ -z "$name" ] && continue
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        methods=()
        check_aws_backup_coverage "$arn" && methods+=("AWS Backup")
        [ "$type" = "Image" ] && methods+=("Container Image")
        [ ${#methods[@]} -gt 0 ] && print_result "OK" "$name" "(Lambda) [${REGION}]" "${methods[*]}" \
            || print_result "FAIL" "$name" "(Lambda) [${REGION}]" ""
    done < <(aws lambda list-functions --region "$REGION" \
        --query 'Functions[*].[FunctionName,FunctionArn,PackageType]' \
        --output text 2>/dev/null || echo "")

    # read-only: describe-repositories, get-lifecycle-policy
    while IFS=$'\t' read -r name arn; do
        [ -z "$name" ] && continue
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        methods=()
        policy=$(aws ecr get-lifecycle-policy --region "$REGION" --repository-name "$name" \
            --query 'lifecyclePolicyText' --output text 2>/dev/null || echo "")
        [ -n "$policy" ] && [ "$policy" != "None" ] && methods+=("Lifecycle Policy")
        [ ${#methods[@]} -gt 0 ] && print_result "OK" "$name" "(ECR) [${REGION}]" "${methods[*]}" \
            || print_result "FAIL" "$name" "(ECR) [${REGION}]" ""
    done < <(aws ecr describe-repositories --region "$REGION" \
        --query 'repositories[*].[repositoryName,repositoryArn]' \
        --output text 2>/dev/null || echo "")
done
echo ""

# --- CONTAINERS (EKS & ECS) ---
echo -e "${BOLD}Kubernetes (EKS) & ECS Volumes${NC}"
echo -e "${DIM}────────────────────────────────────────────────────────────────────${NC}"
for REGION in "${REGIONS[@]}"; do
    # EKS PVC-backed EBS volumes (read-only: describe-volumes + local snapshot cache)
    k8s_vols=$(aws ec2 describe-volumes --region "$REGION" \
        --filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
        --query 'Volumes[*].[VolumeId,Size,Tags[?Key==`kubernetes.io/created-for/pvc/name`].Value|[0]]' \
        --output text 2>/dev/null || echo "")
    if [ -n "$k8s_vols" ]; then
        while IFS=$'\t' read -r id size pvc; do
            [ -z "$id" ] && continue
            TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
            methods=()
            check_aws_backup_coverage "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:volume/${id}" && methods+=("AWS Backup")
            check_dlm_coverage "$id" "$REGION" && methods+=("DLM Policy")

            latest_snap=$(grep "^${id}" "/tmp/aws_ebs_snaps_${REGION}.tmp" 2>/dev/null | sort -k3 -r | head -n 1 || echo "")
            if [ -n "$latest_snap" ]; then
                days_ago=$(get_days_ago "$(echo "$latest_snap" | awk '{print $3}')")
                methods+=("Snapshot: ${days_ago}d ago")
            fi

            [ ${#methods[@]} -gt 0 ] && print_result "OK" "PVC: $pvc" "($id) [${REGION}]" "${methods[*]}" \
                || print_result "FAIL" "PVC: $pvc" "($id) [${REGION}]" ""
        done <<< "$k8s_vols"
    fi

    # ECS Task Volumes (read-only: list-clusters, list-task-definitions, describe-task-definition, efs describe-backup-policy)
    if [ "${SKIP_ECS:-false}" = "true" ]; then
        echo -e "  ${DIM}ECS deep-scan skipped (SKIP_ECS=true).${NC}"
    else
        ecs_clusters=$(aws ecs list-clusters --region "$REGION" \
            --query 'clusterArns[]' --output text 2>/dev/null || echo "")
        for cluster_arn in $ecs_clusters; do
            cluster_name=$(basename "$cluster_arn")

            task_defs=$(timeout 30s aws ecs list-task-definitions --region "$REGION" \
                --status ACTIVE --page-size 20 --max-items 20 --no-paginate \
                --query 'taskDefinitionArns[]' --output text 2>/dev/null || echo "TIMEOUT")

            if [ "$task_defs" = "TIMEOUT" ] || [ -z "$task_defs" ]; then
                continue
            fi

            for task_def_arn in $task_defs; do
                task_def=$(aws ecs describe-task-definition --region "$REGION" \
                    --task-definition "$task_def_arn" \
                    --query 'taskDefinition' --output json 2>/dev/null || echo "{}")
                efs_volumes=$(echo "$task_def" | jq -r \
                    '.volumes[]? | select(.efsVolumeConfiguration != null) | .efsVolumeConfiguration.fileSystemId' \
                    2>/dev/null || echo "")

                if [ -n "$efs_volumes" ]; then
                    while read -r fs_id; do
                        [ -z "$fs_id" ] && continue
                        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
                        methods=()

                        policy=$(aws efs describe-backup-policy --region "$REGION" \
                            --file-system-id "$fs_id" \
                            --query 'BackupPolicy.Status' --output text 2>/dev/null || echo "DISABLED")
                        [ "$policy" = "ENABLED" ] && methods+=("EFS Auto Backup")
                        check_aws_backup_coverage "arn:aws:elasticfilesystem:${REGION}:${ACCOUNT_ID}:file-system/${fs_id}" && methods+=("AWS Backup")

                        [ ${#methods[@]} -gt 0 ] && print_result "OK" "ECS EFS: $fs_id" "($cluster_name) [${REGION}]" "${methods[*]}" \
                            || print_result "FAIL" "ECS EFS: $fs_id" "($cluster_name) [${REGION}]" ""
                    done <<< "$efs_volumes"
                fi
            done
        done
    fi
done
echo ""

# --- S3 BUCKETS ---
echo -e "${BOLD}S3 Buckets${NC}"
echo -e "${DIM}────────────────────────────────────────────────────────────────────${NC}"
# read-only: list-buckets, get-bucket-location, get-bucket-versioning
s3_buckets=$(aws s3api list-buckets --query 'Buckets[*].Name' --output text 2>/dev/null || echo "")
if [ -n "$s3_buckets" ]; then
    for bucket in $s3_buckets; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))

        region=$(aws s3api get-bucket-location --bucket "$bucket" \
            --query 'LocationConstraint' --output text 2>/dev/null || echo "us-east-1")
        [ "$region" = "None" ] || [ "$region" = "null" ] || [ -z "$region" ] && region="us-east-1"

        methods=()
        has_true_backup=false

        # Fixed: removed dead for-loop — check_aws_backup_coverage is region-agnostic
        if check_aws_backup_coverage "arn:aws:s3:::$bucket"; then
            methods+=("AWS Backup")
            has_true_backup=true
        fi

        versioning=$(aws s3api get-bucket-versioning --bucket "$bucket" \
            --query 'Status' --output text 2>/dev/null || echo "None")

        if [ "$has_true_backup" = true ]; then
            print_result "OK" "$bucket" "[${region}]" "${methods[*]}"
        elif [ "$versioning" = "Enabled" ]; then
            print_result "WARN" "$bucket" "[${region}]" "Versioning only (Not a backup)"
        else
            print_result "FAIL" "$bucket" "[${region}]" ""
        fi
    done
fi
echo ""

# ==================== CLEANUP ====================
for REGION in "${REGIONS[@]}"; do
    rm -f "/tmp/aws_ebs_snaps_${REGION}.tmp"
done

# ==================== SUMMARY ====================
echo -e "${BOLD}┌────────────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│  EXECUTIVE SUMMARY                                                 │${NC}"
echo -e "${BOLD}└────────────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "Total Resources Assessed:  ${BOLD}${TOTAL_RESOURCES}${NC}"
echo -e "Protected Infrastructure:  ${BOLD}${BACKED_UP}${NC}"
echo -e "Unprotected / At Risk:     ${BOLD}${NOT_BACKED_UP}${NC}"

if [ "$TOTAL_RESOURCES" -gt 0 ]; then
    coverage=$((BACKED_UP * 100 / TOTAL_RESOURCES))
    echo ""
    if [ "$coverage" -ge 95 ]; then
        echo -e "Compliance Rating:         ${BOLD}${coverage}% (Excellent)${NC}"
    elif [ "$coverage" -ge 80 ]; then
        echo -e "Compliance Rating:         ${BOLD}${coverage}% (Good)${NC}"
    else
        echo -e "Compliance Rating:         ${BOLD}${coverage}% (Needs Review)${NC}"
    fi
fi
echo ""
