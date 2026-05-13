#!/bin/bash

# AWS Comprehensive Backup Audit Script v3.0
# Checks all critical resources for backup coverage including:
# - AWS Backup service coverage
# - Data Lifecycle Manager (DLM) policies
# - Native backup mechanisms
# - All major AWS services
#
# Author: Cloud Ops Team
# Date: 2026-05-13

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Counters
TOTAL_RESOURCES=0
BACKED_UP=0
NOT_BACKED_UP=0
PARTIAL_BACKUP=0

# Arrays to track resources
declare -A RESOURCE_BACKUP_STATUS
declare -A AWS_BACKUP_PROTECTED_RESOURCES

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       AWS COMPREHENSIVE BACKUP COVERAGE AUDIT REPORT v3.0          ║${NC}"
echo -e "${BLUE}║       $(date '+%Y-%m-%d %H:%M:%S %Z')                                    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Get AWS region
REGION=${AWS_REGION:-$(aws configure get region || echo "us-east-1")}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
echo -e "Account ID: ${BLUE}${ACCOUNT_ID}${NC}"
echo -e "Region: ${BLUE}${REGION}${NC}"
echo ""

# ==================== DISCOVER AWS BACKUP PROTECTED RESOURCES ====================
echo -e "${CYAN}[Phase 1/3] Discovering AWS Backup protected resources...${NC}"

# Get all backup vaults
backup_vaults=$(aws backup list-backup-vaults --region "$REGION" --query 'BackupVaultList[*].BackupVaultName' --output text 2>/dev/null || echo "")

if [ -n "$backup_vaults" ]; then
    for vault in $backup_vaults; do
        # Get recovery points in this vault
        recovery_points=$(aws backup list-recovery-points-by-backup-vault \
            --backup-vault-name "$vault" \
            --region "$REGION" \
            --query 'RecoveryPoints[?Status==`COMPLETED`].[ResourceArn]' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$recovery_points" ]; then
            while read -r arn; do
                [ -n "$arn" ] && AWS_BACKUP_PROTECTED_RESOURCES["$arn"]=1
            done <<< "$recovery_points"
        fi
    done
fi

# Get all backup plans and their selections
backup_plans=$(aws backup list-backup-plans --region "$REGION" --query 'BackupPlansList[*].BackupPlanId' --output text 2>/dev/null || echo "")

if [ -n "$backup_plans" ]; then
    for plan_id in $backup_plans; do
        selections=$(aws backup list-backup-selections \
            --backup-plan-id "$plan_id" \
            --region "$REGION" \
            --query 'BackupSelectionsList[*].SelectionId' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$selections" ]; then
            for selection_id in $selections; do
                selection_details=$(aws backup get-backup-selection \
                    --backup-plan-id "$plan_id" \
                    --selection-id "$selection_id" \
                    --region "$REGION" 2>/dev/null || echo "")
                
                # Extract resource ARNs from selection
                if [ -n "$selection_details" ]; then
                    resources=$(echo "$selection_details" | jq -r '.BackupSelection.Resources[]?' 2>/dev/null || echo "")
                    [ -n "$resources" ] && while read -r arn; do
                        [ -n "$arn" ] && AWS_BACKUP_PROTECTED_RESOURCES["$arn"]=1
                    done <<< "$resources"
                fi
            done
        fi
    done
fi

backup_resource_count=$(set +u; echo ${#AWS_BACKUP_PROTECTED_RESOURCES[@]}; set -u)
echo -e "${GREEN}✓${NC} Found ${backup_resource_count} resources protected by AWS Backup"
echo ""

# ==================== DISCOVER DLM POLICIES ====================
echo -e "${CYAN}[Phase 2/3] Discovering Data Lifecycle Manager policies...${NC}"

dlm_policies=$(aws dlm get-lifecycle-policies --region "$REGION" --query 'Policies[?State==`ENABLED`]' --output json 2>/dev/null || echo "[]")
dlm_policy_count=$(echo "$dlm_policies" | jq 'length')

declare -A DLM_PROTECTED_TAGS

if [ "$dlm_policy_count" -gt 0 ]; then
    echo "$dlm_policies" | jq -r '.[] | .PolicyId' | while read -r policy_id; do
        policy_details=$(aws dlm get-lifecycle-policy --policy-id "$policy_id" --region "$REGION" 2>/dev/null || echo "")
        
        if [ -n "$policy_details" ]; then
            # Extract target tags from policy
            target_tags=$(echo "$policy_details" | jq -r '.Policy.PolicyDetails.TargetTags[]? | "\(.Key)=\(.Value)"' 2>/dev/null || echo "")
            if [ -n "$target_tags" ]; then
                while read -r tag; do
                    [ -n "$tag" ] && DLM_PROTECTED_TAGS["$tag"]=1
                done <<< "$target_tags"
            fi
        fi
    done
fi

echo -e "${GREEN}✓${NC} Found ${dlm_policy_count} active DLM policies"
echo ""

# Function to check if resource has AWS Backup coverage
check_aws_backup_coverage() {
    local resource_arn=$1
    if [[ -v "AWS_BACKUP_PROTECTED_RESOURCES[$resource_arn]" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to check if resource is protected by DLM
check_dlm_coverage() {
    local resource_id=$1
    local resource_type=$2  # "instance" or "volume"
    
    # Get tags for the resource
    local tags=""
    if [ "$resource_type" = "instance" ]; then
        tags=$(aws ec2 describe-tags --region "$REGION" \
            --filters "Name=resource-id,Values=${resource_id}" \
            --query 'Tags[].[Key,Value]' --output text 2>/dev/null || echo "")
    elif [ "$resource_type" = "volume" ]; then
        tags=$(aws ec2 describe-tags --region "$REGION" \
            --filters "Name=resource-id,Values=${resource_id}" \
            --query 'Tags[].[Key,Value]' --output text 2>/dev/null || echo "")
    fi
    
    if [ -n "$tags" ]; then
        while IFS=$'\t' read -r key value; do
            local tag_pair="${key}=${value}"
            if [[ -v "DLM_PROTECTED_TAGS[$tag_pair]" ]]; then
                return 0
            fi
        done <<< "$tags"
    fi
    
    return 1
}

echo -e "${CYAN}[Phase 3/3] Auditing resources...${NC}"
echo ""

# ==================== RDS INSTANCES ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}RDS Database Instances${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

rds_instances=$(aws rds describe-db-instances --region "$REGION" --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceArn,Engine,BackupRetentionPeriod]' --output text 2>/dev/null || echo "")

if [ -z "$rds_instances" ]; then
    echo -e "${YELLOW}No RDS instances found${NC}"
else
    while IFS=$'\t' read -r db_id db_arn engine retention; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        has_native_backup=false
        has_aws_backup=false
        backup_methods=()
        
        # Check native automated backups
        if [ "$retention" -gt 0 ]; then
            has_native_backup=true
            backup_methods+=("Native: ${retention}d")
        fi
        
        # Check AWS Backup
        if check_aws_backup_coverage "$db_arn"; then
            has_aws_backup=true
            backup_methods+=("AWS Backup")
        fi
        
        # Check for manual snapshots
        manual_snapshots=$(aws rds describe-db-snapshots --region "$REGION" \
            --db-instance-identifier "$db_id" \
            --snapshot-type manual \
            --query 'DBSnapshots[0]' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$manual_snapshots" ] && [ "$manual_snapshots" != "None" ]; then
            backup_methods+=("Manual snapshots")
        fi
        
        # Determine status
        if [ "$has_native_backup" = true ] || [ "$has_aws_backup" = true ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $db_id (${engine}) - ${backup_methods[*]}"
        elif [ ${#backup_methods[@]} -gt 0 ]; then
            PARTIAL_BACKUP=$((PARTIAL_BACKUP + 1))
            echo -e "  ${YELLOW}⚠${NC} $db_id (${engine}) - Only: ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $db_id (${engine}) - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done <<< "$rds_instances"
fi
echo ""

# ==================== RDS CLUSTERS ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}RDS Clusters (Aurora)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

rds_clusters=$(aws rds describe-db-clusters --region "$REGION" --query 'DBClusters[*].[DBClusterIdentifier,DBClusterArn,Engine,BackupRetentionPeriod]' --output text 2>/dev/null || echo "")

if [ -z "$rds_clusters" ]; then
    echo -e "${YELLOW}No RDS clusters found${NC}"
else
    while IFS=$'\t' read -r cluster_id cluster_arn engine retention; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        
        if [ "$retention" -gt 0 ]; then
            backup_methods+=("Native: ${retention}d")
        fi
        
        if check_aws_backup_coverage "$cluster_arn"; then
            backup_methods+=("AWS Backup")
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $cluster_id (${engine}) - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $cluster_id (${engine}) - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done <<< "$rds_clusters"
fi
echo ""

# ==================== EC2 INSTANCES ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}EC2 Instances${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ec2_instances=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name]' \
    --output text 2>/dev/null || echo "")

if [ -z "$ec2_instances" ]; then
    echo -e "${YELLOW}No EC2 instances found${NC}"
else
    while IFS=$'\t' read -r instance_id name state; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        instance_arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/${instance_id}"
        
        # Check AWS Backup
        if check_aws_backup_coverage "$instance_arn"; then
            backup_methods+=("AWS Backup")
        fi
        
        # Check DLM
        if check_dlm_coverage "$instance_id" "instance"; then
            backup_methods+=("DLM Policy")
        fi
        
        # Check for AMIs (any age)
        latest_ami=$(aws ec2 describe-images --region "$REGION" \
            --filters "Name=name,Values=*${instance_id}*" \
            --query 'Images | sort_by(@, &CreationDate)[-1].[ImageId,CreationDate]' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$latest_ami" ] && [ "$latest_ami" != "None" ]; then
            ami_id=$(echo "$latest_ami" | awk '{print $1}')
            ami_date=$(echo "$latest_ami" | awk '{print $2}')
            
            # Calculate days ago
            if [ -n "$ami_date" ]; then
                ami_epoch=$(date -d "$ami_date" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${ami_date}T00:00:00" +%s 2>/dev/null || echo "0")
                current_epoch=$(date +%s)
                days_ago=$(( (current_epoch - ami_epoch) / 86400 ))
                backup_methods+=("AMI: ${days_ago}d ago")
            else
                backup_methods+=("Has AMI")
            fi
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $instance_id (${name:-N/A}) [$state] - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $instance_id (${name:-N/A}) [$state] - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done <<< "$ec2_instances"
fi
echo ""

# ==================== EBS VOLUMES ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}EBS Volumes${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ebs_volumes=$(aws ec2 describe-volumes --region "$REGION" \
    --query 'Volumes[*].[VolumeId,Size,State,Attachments[0].InstanceId]' \
    --output text 2>/dev/null || echo "")

if [ -z "$ebs_volumes" ]; then
    echo -e "${YELLOW}No EBS volumes found${NC}"
else
    while IFS=$'\t' read -r volume_id size state instance_id; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        volume_arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:volume/${volume_id}"
        
        # Check AWS Backup
        if check_aws_backup_coverage "$volume_arn"; then
            backup_methods+=("AWS Backup")
        fi
        
        # Check DLM
        if check_dlm_coverage "$volume_id" "volume"; then
            backup_methods+=("DLM Policy")
        fi
        
        # Check for snapshots (any age)
        snapshot_count=$(aws ec2 describe-snapshots --region "$REGION" \
            --filters "Name=volume-id,Values=${volume_id}" \
            --query 'length(Snapshots)' \
            --output text 2>/dev/null || echo "0")
        
        if [ "$snapshot_count" -gt 0 ]; then
            # Get the most recent snapshot
            latest_snapshot=$(aws ec2 describe-snapshots --region "$REGION" \
                --filters "Name=volume-id,Values=${volume_id}" \
                --query 'Snapshots | sort_by(@, &StartTime)[-1].[SnapshotId,StartTime]' \
                --output text 2>/dev/null || echo "")
            
            if [ -n "$latest_snapshot" ]; then
                snapshot_id=$(echo "$latest_snapshot" | awk '{print $1}')
                snapshot_date=$(echo "$latest_snapshot" | awk '{print $2}')
                
                # Calculate days ago
                if [ -n "$snapshot_date" ]; then
                    snapshot_epoch=$(date -d "$snapshot_date" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "$snapshot_date" +%s 2>/dev/null || echo "0")
                    if [ "$snapshot_epoch" != "0" ]; then
                        current_epoch=$(date +%s)
                        days_ago=$(( (current_epoch - snapshot_epoch) / 86400 ))
                        backup_methods+=("Snapshot: ${days_ago}d ago")
                    else
                        backup_methods+=("Has snapshots")
                    fi
                else
                    backup_methods+=("Has snapshots")
                fi
            else
                backup_methods+=("Has snapshots")
            fi
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $volume_id (${size}GB) [${instance_id:-unattached}] - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $volume_id (${size}GB) [${instance_id:-unattached}] - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done <<< "$ebs_volumes"
fi
echo ""

# ==================== DYNAMODB TABLES ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}DynamoDB Tables${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

dynamodb_tables=$(aws dynamodb list-tables --region "$REGION" --query 'TableNames[]' --output text 2>/dev/null || echo "")

if [ -z "$dynamodb_tables" ]; then
    echo -e "${YELLOW}No DynamoDB tables found${NC}"
else
    for table in $dynamodb_tables; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        
        # Get table ARN
        table_arn=$(aws dynamodb describe-table --region "$REGION" \
            --table-name "$table" \
            --query 'Table.TableArn' \
            --output text 2>/dev/null || echo "")
        
        # Check PITR
        pitr_status=$(aws dynamodb describe-continuous-backups --region "$REGION" \
            --table-name "$table" \
            --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' \
            --output text 2>/dev/null || echo "DISABLED")
        
        if [ "$pitr_status" = "ENABLED" ]; then
            backup_methods+=("PITR")
        fi
        
        # Check AWS Backup
        if [ -n "$table_arn" ] && check_aws_backup_coverage "$table_arn"; then
            backup_methods+=("AWS Backup")
        fi
        
        # Check for on-demand backups
        on_demand_backups=$(aws dynamodb list-backups --region "$REGION" \
            --table-name "$table" \
            --backup-type USER \
            --query 'BackupSummaries[0]' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$on_demand_backups" ] && [ "$on_demand_backups" != "None" ]; then
            backup_methods+=("On-demand backups")
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $table - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $table - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done
fi
echo ""

# ==================== EFS FILE SYSTEMS ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}EFS File Systems${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

efs_filesystems=$(aws efs describe-file-systems --region "$REGION" \
    --query 'FileSystems[*].[FileSystemId,Name,FileSystemArn]' \
    --output text 2>/dev/null || echo "")

if [ -z "$efs_filesystems" ]; then
    echo -e "${YELLOW}No EFS file systems found${NC}"
else
    while IFS=$'\t' read -r fs_id fs_name fs_arn; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        
        # Check native EFS backup policy
        backup_policy=$(aws efs describe-backup-policy --region "$REGION" \
            --file-system-id "$fs_id" \
            --query 'BackupPolicy.Status' \
            --output text 2>/dev/null || echo "DISABLED")
        
        if [ "$backup_policy" = "ENABLED" ]; then
            backup_methods+=("EFS Auto Backup")
        fi
        
        # Check AWS Backup
        if check_aws_backup_coverage "$fs_arn"; then
            backup_methods+=("AWS Backup")
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $fs_id (${fs_name:-N/A}) - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $fs_id (${fs_name:-N/A}) - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done <<< "$efs_filesystems"
fi
echo ""

# ==================== FSX FILE SYSTEMS ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}FSx File Systems${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

fsx_filesystems=$(aws fsx describe-file-systems --region "$REGION" \
    --query 'FileSystems[*].[FileSystemId,FileSystemType,ResourceARN]' \
    --output text 2>/dev/null || echo "")

if [ -z "$fsx_filesystems" ]; then
    echo -e "${YELLOW}No FSx file systems found${NC}"
else
    while IFS=$'\t' read -r fs_id fs_type fs_arn; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        
        # Check for automatic backups
        auto_backup=$(aws fsx describe-file-systems --region "$REGION" \
            --file-system-ids "$fs_id" \
            --query 'FileSystems[0].WindowsConfiguration.AutomaticBackupRetentionDays // FileSystems[0].LustreConfiguration.AutomaticBackupRetentionDays // FileSystems[0].OntapConfiguration.AutomaticBackupRetentionDays // FileSystems[0].OpenZFSConfiguration.AutomaticBackupRetentionDays' \
            --output text 2>/dev/null || echo "0")
        
        if [ "$auto_backup" != "0" ] && [ "$auto_backup" != "None" ]; then
            backup_methods+=("Auto backup: ${auto_backup}d")
        fi
        
        # Check AWS Backup
        if check_aws_backup_coverage "$fs_arn"; then
            backup_methods+=("AWS Backup")
        fi
        
        # Check for manual backups
        manual_backups=$(aws fsx describe-backups --region "$REGION" \
            --filters "Name=file-system-id,Values=${fs_id}" \
            --query 'Backups[?Type==`USER_INITIATED`] | [0]' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$manual_backups" ] && [ "$manual_backups" != "None" ]; then
            backup_methods+=("Manual backups")
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $fs_id (${fs_type}) - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $fs_id (${fs_type}) - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done <<< "$fsx_filesystems"
fi
echo ""

# ==================== DOCUMENTDB CLUSTERS ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}DocumentDB Clusters${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

docdb_clusters=$(aws docdb describe-db-clusters --region "$REGION" \
    --query 'DBClusters[*].[DBClusterIdentifier,DBClusterArn,BackupRetentionPeriod]' \
    --output text 2>/dev/null || echo "")

if [ -z "$docdb_clusters" ]; then
    echo -e "${YELLOW}No DocumentDB clusters found${NC}"
else
    while IFS=$'\t' read -r cluster_id cluster_arn retention; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        
        if [ "$retention" -gt 0 ]; then
            backup_methods+=("Native: ${retention}d")
        fi
        
        if check_aws_backup_coverage "$cluster_arn"; then
            backup_methods+=("AWS Backup")
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $cluster_id - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $cluster_id - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done <<< "$docdb_clusters"
fi
echo ""

# ==================== NEPTUNE CLUSTERS ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Neptune Clusters${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

neptune_clusters=$(aws neptune describe-db-clusters --region "$REGION" \
    --query 'DBClusters[*].[DBClusterIdentifier,DBClusterArn,BackupRetentionPeriod]' \
    --output text 2>/dev/null || echo "")

if [ -z "$neptune_clusters" ]; then
    echo -e "${YELLOW}No Neptune clusters found${NC}"
else
    while IFS=$'\t' read -r cluster_id cluster_arn retention; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        
        if [ "$retention" -gt 0 ]; then
            backup_methods+=("Native: ${retention}d")
        fi
        
        if check_aws_backup_coverage "$cluster_arn"; then
            backup_methods+=("AWS Backup")
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $cluster_id - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $cluster_id - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done <<< "$neptune_clusters"
fi
echo ""

# ==================== REDSHIFT CLUSTERS ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Redshift Clusters${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

redshift_clusters=$(aws redshift describe-clusters --region "$REGION" \
    --query 'Clusters[*].[ClusterIdentifier,AutomatedSnapshotRetentionPeriod]' \
    --output text 2>/dev/null || echo "")

if [ -z "$redshift_clusters" ]; then
    echo -e "${YELLOW}No Redshift clusters found${NC}"
else
    while IFS=$'\t' read -r cluster_id retention; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        cluster_arn="arn:aws:redshift:${REGION}:${ACCOUNT_ID}:cluster:${cluster_id}"
        
        if [ "$retention" -gt 0 ]; then
            backup_methods+=("Auto snapshot: ${retention}d")
        fi
        
        if check_aws_backup_coverage "$cluster_arn"; then
            backup_methods+=("AWS Backup")
        fi
        
        # Check for manual snapshots
        manual_snapshots=$(aws redshift describe-cluster-snapshots --region "$REGION" \
            --cluster-identifier "$cluster_id" \
            --snapshot-type manual \
            --query 'Snapshots[0]' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$manual_snapshots" ] && [ "$manual_snapshots" != "None" ]; then
            backup_methods+=("Manual snapshots")
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $cluster_id - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $cluster_id - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done <<< "$redshift_clusters"
fi
echo ""

# ==================== ELASTICACHE REDIS CLUSTERS ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}ElastiCache Redis Clusters${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

elasticache_clusters=$(aws elasticache describe-replication-groups --region "$REGION" \
    --query 'ReplicationGroups[*].[ReplicationGroupId,SnapshotRetentionLimit,ARN]' \
    --output text 2>/dev/null || echo "")

if [ -z "$elasticache_clusters" ]; then
    echo -e "${YELLOW}No ElastiCache Redis clusters found${NC}"
else
    while IFS=$'\t' read -r cluster_id retention cluster_arn; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        
        if [ "$retention" -gt 0 ]; then
            backup_methods+=("Auto backup: ${retention}d")
        fi
        
        if check_aws_backup_coverage "$cluster_arn"; then
            backup_methods+=("AWS Backup")
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $cluster_id - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $cluster_id - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done <<< "$elasticache_clusters"
fi
echo ""

# ==================== MEMORYDB CLUSTERS ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}MemoryDB Clusters${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

memorydb_clusters=$(aws memorydb describe-clusters --region "$REGION" \
    --query 'Clusters[*].[Name,SnapshotRetentionLimit,ARN]' \
    --output text 2>/dev/null || echo "")

if [ -z "$memorydb_clusters" ]; then
    echo -e "${YELLOW}No MemoryDB clusters found${NC}"
else
    while IFS=$'\t' read -r cluster_name retention cluster_arn; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        
        if [ "$retention" -gt 0 ]; then
            backup_methods+=("Auto snapshot: ${retention}d")
        fi
        
        if check_aws_backup_coverage "$cluster_arn"; then
            backup_methods+=("AWS Backup")
        fi
        
        # Check for snapshots
        snapshots=$(aws memorydb describe-snapshots --region "$REGION" \
            --cluster-name "$cluster_name" \
            --query 'Snapshots[0]' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$snapshots" ] && [ "$snapshots" != "None" ]; then
            backup_methods+=("Snapshots exist")
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $cluster_name - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $cluster_name - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done <<< "$memorydb_clusters"
fi
echo ""

# ==================== LAMBDA FUNCTIONS ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Lambda Functions${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

lambda_functions=$(aws lambda list-functions --region "$REGION" \
    --query 'Functions[*].[FunctionName,FunctionArn,PackageType]' \
    --output text 2>/dev/null || echo "")

if [ -z "$lambda_functions" ]; then
    echo -e "${YELLOW}No Lambda functions found${NC}"
else
    while IFS=$'\t' read -r func_name func_arn package_type; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        
        # Check for versions (code backups)
        versions=$(aws lambda list-versions-by-function --region "$REGION" \
            --function-name "$func_name" \
            --query 'Versions[?Version!=`$LATEST`] | length(@)' \
            --output text 2>/dev/null || echo "0")
        
        if [ "$versions" -gt 0 ]; then
            backup_methods+=("${versions} versions")
        fi
        
        # Check if using container image (ECR)
        if [ "$package_type" = "Image" ]; then
            backup_methods+=("Container image in ECR")
        fi
        
        # Check AWS Backup
        if check_aws_backup_coverage "$func_arn"; then
            backup_methods+=("AWS Backup")
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $func_name - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $func_name - ${RED}NO BACKUPS FOUND${NC}"
        fi
    done <<< "$lambda_functions"
fi
echo ""

# ==================== ECR REPOSITORIES ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}ECR Repositories${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ecr_repos=$(aws ecr describe-repositories --region "$REGION" \
    --query 'repositories[*].[repositoryName,repositoryArn]' \
    --output text 2>/dev/null || echo "")

if [ -z "$ecr_repos" ]; then
    echo -e "${YELLOW}No ECR repositories found${NC}"
else
    while IFS=$'\t' read -r repo_name repo_arn; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        
        # Check for lifecycle policy (image retention)
        lifecycle_policy=$(aws ecr get-lifecycle-policy --region "$REGION" \
            --repository-name "$repo_name" \
            --query 'lifecyclePolicyText' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$lifecycle_policy" ] && [ "$lifecycle_policy" != "None" ]; then
            backup_methods+=("Lifecycle policy")
        fi
        
        # Check for replication
        replication=$(aws ecr describe-registry --region "$REGION" \
            --query 'replicationConfiguration.rules[0].destinations[0].region' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$replication" ] && [ "$replication" != "None" ]; then
            backup_methods+=("Cross-region replication")
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $repo_name - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $repo_name - ${RED}NO BACKUP STRATEGY${NC}"
        fi
    done <<< "$ecr_repos"
fi
echo ""

# ==================== EKS PERSISTENT VOLUMES ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}EKS Persistent Volumes (EBS-backed)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Get EKS clusters
eks_clusters=$(aws eks list-clusters --region "$REGION" --query 'clusters[]' --output text 2>/dev/null || echo "")

if [ -z "$eks_clusters" ]; then
    echo -e "${YELLOW}No EKS clusters found${NC}"
else
    # For each cluster, we need to check for EBS volumes tagged with kubernetes.io/created-for/pvc
    for cluster in $eks_clusters; do
        echo -e "${CYAN}  Cluster: $cluster${NC}"
        
        # Find EBS volumes tagged as Kubernetes PVs
        k8s_volumes=$(aws ec2 describe-volumes --region "$REGION" \
            --filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
            --query 'Volumes[*].[VolumeId,Size,Tags[?Key==`kubernetes.io/created-for/pvc/name`].Value|[0]]' \
            --output text 2>/dev/null || echo "")
        
        if [ -z "$k8s_volumes" ]; then
            echo -e "    ${YELLOW}No persistent volumes found${NC}"
        else
            while IFS=$'\t' read -r volume_id size pvc_name; do
                TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
                
                backup_methods=()
                volume_arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:volume/${volume_id}"
                
                # Check AWS Backup
                if check_aws_backup_coverage "$volume_arn"; then
                    backup_methods+=("AWS Backup")
                fi
                
                # Check DLM
                if check_dlm_coverage "$volume_id" "volume"; then
                    backup_methods+=("DLM Policy")
                fi
                
                # Check for snapshots (any age)
                latest_snapshot=$(aws ec2 describe-snapshots --region "$REGION" \
                    --filters "Name=volume-id,Values=${volume_id}" \
                    --query 'Snapshots | sort_by(@, &StartTime)[-1].[SnapshotId,StartTime]' \
                    --output text 2>/dev/null || echo "")
                
                if [ -n "$latest_snapshot" ] && [ "$latest_snapshot" != "None" ]; then
                    snapshot_date=$(echo "$latest_snapshot" | awk '{print $2}')
                    if [ -n "$snapshot_date" ]; then
                        snapshot_epoch=$(date -d "$snapshot_date" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "$snapshot_date" +%s 2>/dev/null || echo "0")
                        current_epoch=$(date +%s)
                        days_ago=$(( (current_epoch - snapshot_epoch) / 86400 ))
                        backup_methods+=("Snapshot: ${days_ago}d ago")
                    else
                        backup_methods+=("Has snapshots")
                    fi
                fi
                
                if [ ${#backup_methods[@]} -gt 0 ]; then
                    BACKED_UP=$((BACKED_UP + 1))
                    echo -e "    ${GREEN}✓${NC} PVC: $pvc_name ($volume_id, ${size}GB) - ${backup_methods[*]}"
                else
                    NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
                    echo -e "    ${RED}✗${NC} PVC: $pvc_name ($volume_id, ${size}GB) - ${RED}NO BACKUPS FOUND${NC}"
                fi
            done <<< "$k8s_volumes"
        fi
    done
fi
echo ""

# ==================== ECS PERSISTENT VOLUMES ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}ECS Task Volumes (EBS/EFS)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Get ECS clusters
ecs_clusters=$(aws ecs list-clusters --region "$REGION" --query 'clusterArns[]' --output text 2>/dev/null || echo "")

if [ -z "$ecs_clusters" ]; then
    echo -e "${YELLOW}No ECS clusters found${NC}"
else
    for cluster_arn in $ecs_clusters; do
        cluster_name=$(basename "$cluster_arn")
        echo -e "${CYAN}  Cluster: $cluster_name${NC}"
        
        # Get task definitions with volumes
        task_defs=$(aws ecs list-task-definitions --region "$REGION" \
            --status ACTIVE \
            --query 'taskDefinitionArns[]' \
            --output text 2>/dev/null || echo "")
        
        found_volumes=false
        
        for task_def_arn in $task_defs; do
            task_def=$(aws ecs describe-task-definition --region "$REGION" \
                --task-definition "$task_def_arn" \
                --query 'taskDefinition' \
                --output json 2>/dev/null || echo "{}")
            
            # Check for EFS volumes
            efs_volumes=$(echo "$task_def" | jq -r '.volumes[]? | select(.efsVolumeConfiguration != null) | .efsVolumeConfiguration.fileSystemId' 2>/dev/null || echo "")
            
            if [ -n "$efs_volumes" ]; then
                found_volumes=true
                while read -r fs_id; do
                    [ -z "$fs_id" ] && continue
                    TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
                    
                    local backup_methods=()
                    local fs_arn="arn:aws:elasticfilesystem:${REGION}:${ACCOUNT_ID}:file-system/${fs_id}"
                    
                    # Check EFS backup policy
                    backup_policy=$(aws efs describe-backup-policy --region "$REGION" \
                        --file-system-id "$fs_id" \
                        --query 'BackupPolicy.Status' \
                        --output text 2>/dev/null || echo "DISABLED")
                    
                    if [ "$backup_policy" = "ENABLED" ]; then
                        backup_methods+=("EFS Auto Backup")
                    fi
                    
                    if check_aws_backup_coverage "$fs_arn"; then
                        backup_methods+=("AWS Backup")
                    fi
                    
                    if [ ${#backup_methods[@]} -gt 0 ]; then
                        BACKED_UP=$((BACKED_UP + 1))
                        echo -e "    ${GREEN}✓${NC} EFS Volume: $fs_id - ${backup_methods[*]}"
                    else
                        NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
                        echo -e "    ${RED}✗${NC} EFS Volume: $fs_id - ${RED}NO BACKUPS FOUND${NC}"
                    fi
                done <<< "$efs_volumes"
            fi
        done
        
        if [ "$found_volumes" = false ]; then
            echo -e "    ${YELLOW}No persistent volumes found${NC}"
        fi
    done
fi
echo ""

# ==================== S3 BUCKETS ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}S3 Buckets${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

s3_buckets=$(aws s3api list-buckets --query 'Buckets[*].Name' --output text 2>/dev/null || echo "")

if [ -z "$s3_buckets" ]; then
    echo -e "${YELLOW}No S3 buckets found${NC}"
else
    for bucket in $s3_buckets; do
        TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
        
        backup_methods=()
        
        # Check versioning
        versioning=$(aws s3api get-bucket-versioning --bucket "$bucket" \
            --query 'Status' --output text 2>/dev/null || echo "None")
        
        if [ "$versioning" = "Enabled" ]; then
            backup_methods+=("Versioning")
        fi
        
        # Check replication
        replication=$(aws s3api get-bucket-replication --bucket "$bucket" \
            --query 'ReplicationConfiguration.Rules[0].Status' \
            --output text 2>/dev/null || echo "None")
        
        if [ "$replication" = "Enabled" ]; then
            backup_methods+=("Replication")
        fi
        
        # Check for S3 Batch Replication
        batch_jobs=$(aws s3control list-jobs --region "$REGION" --account-id "$ACCOUNT_ID" \
            --job-statuses Active --query "Jobs[?contains(Description, '${bucket}')]" \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$batch_jobs" ]; then
            backup_methods+=("Batch Replication")
        fi
        
        if [ ${#backup_methods[@]} -gt 0 ]; then
            BACKED_UP=$((BACKED_UP + 1))
            echo -e "  ${GREEN}✓${NC} $bucket - ${backup_methods[*]}"
        else
            NOT_BACKED_UP=$((NOT_BACKED_UP + 1))
            echo -e "  ${RED}✗${NC} $bucket - ${RED}NO PROTECTION${NC}"
        fi
    done
fi
echo ""

# ==================== AWS BACKUP SUMMARY ====================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}AWS Backup Infrastructure${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Backup Plans
backup_plans_list=$(aws backup list-backup-plans --region "$REGION" --output json 2>/dev/null || echo '{"BackupPlansList":[]}')
plan_count=$(echo "$backup_plans_list" | jq '.BackupPlansList | length')

echo -e "${MAGENTA}Backup Plans:${NC} $plan_count configured"
if [ "$plan_count" -gt 0 ]; then
    echo "$backup_plans_list" | jq -r '.BackupPlansList[] | "  • \(.BackupPlanName) (\(.BackupPlanId))"'
fi

# Backup Vaults
echo ""
vault_count=$(echo "$backup_vaults" | wc -w)
echo -e "${MAGENTA}Backup Vaults:${NC} $vault_count configured"
if [ "$vault_count" -gt 0 ]; then
    for vault in $backup_vaults; do
        recovery_point_count=$(aws backup list-recovery-points-by-backup-vault \
            --backup-vault-name "$vault" \
            --region "$REGION" \
            --query 'length(RecoveryPoints)' \
            --output text 2>/dev/null || echo "0")
        echo -e "  • $vault (${recovery_point_count} recovery points)"
    done
fi

# DLM Policies
echo ""
echo -e "${MAGENTA}DLM Policies:${NC} $dlm_policy_count active"
if [ "$dlm_policy_count" -gt 0 ]; then
    echo "$dlm_policies" | jq -r '.[] | "  • \(.PolicyId): \(.Description // "No description")"'
fi

echo ""

# ==================== SUMMARY ====================
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                           SUMMARY                                  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Total Resources Checked:      ${BLUE}${TOTAL_RESOURCES}${NC}"
echo -e "Resources with Backups:       ${GREEN}${BACKED_UP}${NC}"
echo -e "Resources without Backups:    ${RED}${NOT_BACKED_UP}${NC}"

if [ "$PARTIAL_BACKUP" -gt 0 ]; then
    echo -e "Resources with Partial Cover: ${YELLOW}${PARTIAL_BACKUP}${NC}"
fi

if [ "$TOTAL_RESOURCES" -gt 0 ]; then
    coverage=$((BACKED_UP * 100 / TOTAL_RESOURCES))
    echo ""
    if [ "$coverage" -ge 95 ]; then
        echo -e "Backup Coverage:              ${GREEN}${coverage}%${NC} ${GREEN}(Excellent)${NC}"
    elif [ "$coverage" -ge 80 ]; then
        echo -e "Backup Coverage:              ${GREEN}${coverage}%${NC} ${GREEN}(Good)${NC}"
    elif [ "$coverage" -ge 60 ]; then
        echo -e "Backup Coverage:              ${YELLOW}${coverage}%${NC} ${YELLOW}(Fair - needs improvement)${NC}"
    else
        echo -e "Backup Coverage:              ${RED}${coverage}%${NC} ${RED}(Critical - immediate attention needed)${NC}"
    fi
fi

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}Services Audited:${NC}"
echo -e "  • RDS Instances & Clusters (Aurora)"
echo -e "  • EC2 Instances & EBS Volumes"
echo -e "  • DynamoDB Tables"
echo -e "  • EFS & FSx File Systems"
echo -e "  • DocumentDB, Neptune, Redshift"
echo -e "  • ElastiCache Redis & MemoryDB"
echo -e "  • Lambda Functions"
echo -e "  • ECR Repositories"
echo -e "  • EKS & ECS Persistent Volumes"
echo -e "  • S3 Buckets"
echo ""
echo -e "${CYAN}Backup Methods Checked:${NC}"
echo -e "  • AWS Backup (recovery points & backup plans)"
echo -e "  • Data Lifecycle Manager (DLM) policies"
echo -e "  • Native service backups (retention periods, PITR)"
echo -e "  • Manual snapshots and backups"
echo -e "  • S3 versioning and replication"
echo -e "  • Lambda versions & ECR image retention"
echo ""
echo -e "Report generated: $(date)"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
