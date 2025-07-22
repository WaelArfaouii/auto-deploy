#!/bin/bash
set -e

S3_BUCKET="scheme-management-qa-deployments"
CONFIG_DIR="$(dirname "$0")/deployments-config"
FRONT_SCRIPT="$(dirname "$0")/frontend/front-auto-deploy.sh"
BACK_SCRIPT="$(dirname "$0")/backend/back-auto-deploy.sh"

mkdir -p "$CONFIG_DIR"

echo "📋 Saving current local config list..."
# Save list of config files BEFORE syncing
OLD_CONFIGS=()
for file in "$CONFIG_DIR"/*.json; do
  [ -e "$file" ] && OLD_CONFIGS+=("$(basename "$file")")
done

echo "📥 Syncing configs from s3://$S3_BUCKET"
aws s3 sync "s3://$S3_BUCKET" "$CONFIG_DIR" --delete --exclude "*" --include "*.json"

echo "📋 Saving new config list..."
# Save list AFTER sync
NEW_CONFIGS=()
for file in "$CONFIG_DIR"/*.json; do
  [ -e "$file" ] && NEW_CONFIGS+=("$(basename "$file")")
done

# 🔍 Compare old and new configs to find deleted ones
for old_file in "${OLD_CONFIGS[@]}"; do
  found=false
  for new_file in "${NEW_CONFIGS[@]}"; do
    if [[ "$old_file" == "$new_file" ]]; then
      found=true
      break
    fi
  done

  if ! $found; then
    deploy_name="${old_file%.json}"
    echo "🗑 Config $old_file was removed from S3 — cleaning up deployment..."

    echo "➡️ Deleting frontend-$deploy_name"
    bash "$FRONT_SCRIPT" delete "$old_file" || echo "⚠️ Failed frontend delete"

    echo "➡️ Deleting backend-$deploy_name"
    bash "$BACK_SCRIPT" delete "$old_file" || echo "⚠️ Failed backend delete"

    echo "🧹 Removing local config file: $old_file"
    rm -f "$CONFIG_DIR/$old_file"
  fi
done

# 💾 Get list of current config names (without .json)
declare -A CONFIG_NAMES
for config_path in "$CONFIG_DIR"/*.json; do
  [ -e "$config_path" ] || continue
  name=$(jq -r '.deploy_name' "$config_path")
  CONFIG_NAMES["$name"]=1
done

# 📦 Deploy or update all present configs
for deploy_name in "${!CONFIG_NAMES[@]}"; do
  echo "🔄 Checking deployment: $deploy_name"

  BACKEND_DEPLOYMENT="backend-$deploy_name"
  FRONTEND_DEPLOYMENT="frontend-$deploy_name"

  BACKEND_EXISTS=$(kubectl get deployment "$BACKEND_DEPLOYMENT" -n qa-backend --ignore-not-found)
  FRONTEND_EXISTS=$(kubectl get deployment "$FRONTEND_DEPLOYMENT" -n qa-frontend --ignore-not-found)

  if [[ -z "$BACKEND_EXISTS" || -z "$FRONTEND_EXISTS" ]]; then
    echo "🚀 Deploying $deploy_name..."
    bash "$FRONT_SCRIPT" deploy "$deploy_name.json"
    bash "$BACK_SCRIPT" deploy "$deploy_name.json"
    echo "✅ Deployed $deploy_name"
  else
    echo "✅ $deploy_name already deployed. Skipping."
  fi

  echo ""
done
echo "🔧 Updating ALB listener default target group..."
aws elbv2 modify-listener \
    --listener-arn arn:aws:elasticloadbalancing:eu-west-2:619403130511:listener/app/qa-backend-alb/694e596982a6402d/b2d88824ec73e324 \
    --default-actions Type=forward,TargetGroupArn=arn:aws:elasticloadbalancing:eu-west-2:619403130511:targetgroup/k8s-qabacken-backendn-72a359fb81/bf1db6f7148e4203
echo "✅ ALB listener updated."

echo "🌍 Running final Terraform apply..."
cd "$(dirname "$0")/../"
terraform init -input=false
terraform apply -auto-approve -var-file=integration.tfvars
echo "✅ Terraform provisioning complete."



