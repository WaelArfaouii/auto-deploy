#!/bin/bash
set -euo pipefail

# Resolve script directory (absolute path)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === 📂 Paths ===
TEMPLATE_DIR="$SCRIPT_DIR/templates"
DEPLOYMENTS_DIR="$SCRIPT_DIR/deployments"
CONFIG_DIR="$(realpath "$SCRIPT_DIR/../deployments-config")"
INGRESS_FILE="$SCRIPT_DIR/ingress.yaml"
TFVARS_FILE="$(realpath "$SCRIPT_DIR/../../integration.tfvars")"

ACTION=${1:-}
CONFIG_FILE=${2:-}

# Validate Arguments
if [[ -z "$ACTION" || -z "$CONFIG_FILE" ]]; then
  echo "❌ Usage: $0 <deploy|delete> <config-file>.json"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "❌ 'jq' is required but not installed."
  exit 1
fi

CONFIG_PATH="$CONFIG_DIR/$CONFIG_FILE"
COGNITO_CONFIG="$SCRIPT_DIR/../cognito-config/${CONFIG_FILE%.json}.json"

if [[ ! -f "$CONFIG_PATH" ]] && [[ "$ACTION" == "deploy" ]]; then
  echo "❌ Config file not found: $CONFIG_PATH"
  exit 1
fi

if [[ "$ACTION" == "deploy" && ! -f "$COGNITO_CONFIG" ]]; then
  echo "❌ Cognito config not found: $COGNITO_CONFIG"
  exit 1
fi


# Load Variables
DEPLOY_NAME=$(jq -r '.deploy_name' "$CONFIG_PATH" 2>/dev/null || echo "${CONFIG_FILE%.json}")
IMAGE_TAG="729f9e54"

if [[ "$ACTION" == "deploy" ]]; then
  USER_POOL_ID=$(jq -r '.cognito_user_pool_id' "$COGNITO_CONFIG")
  CLIENT_ID=$(jq -r '.cognito_client_id' "$COGNITO_CONFIG")
  COGNITO_REGION=$(jq -r '.cognito_region' "$COGNITO_CONFIG")
  COGNITO_ISSUER=$(jq -r '.cognito_issuer_uri' "$COGNITO_CONFIG")
  COGNITO_USER_POOL_ARN=$(jq -r '.cognito_user_pool_arn' "$COGNITO_CONFIG")
else
  USER_POOL_ID=""
  CLIENT_ID=""
  COGNITO_REGION=""
  COGNITO_ISSUER=""
  COGNITO_USER_POOL_ARN=""
fi


DEPLOY_DIR="$DEPLOYMENTS_DIR/$DEPLOY_NAME"
DB_NAME="${DEPLOY_NAME}-db"
RDS_HOST="scheme-management-qa-rds.chqku6ou6f3a.eu-west-2.rds.amazonaws.com"
DB_USER="userqa"
: "${DB_PASSWORD:?DB_PASSWORD must be set}"


create_db_via_bastion() {
  echo "🔐 Creating DB $DB_NAME..."
    export PGPASSWORD="$DB_PASSWORD"
    psql -h "$RDS_HOST" -U "$DB_USER" -d postgres -c "CREATE DATABASE \"$DB_NAME\""
    echo "✅ Database $DB_NAME created."
}

drop_db_via_bastion() {
  echo "🧸 Dropping DB $DB_NAME (force)..."
    export PGPASSWORD="$DB_PASSWORD"
    psql -h "$RDS_HOST" -U "$DB_USER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME';"
    psql -h "$RDS_HOST" -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\";"
    echo "✅ Database $DB_NAME force-dropped."
}

S3_BUCKET_NAME="scheme-management-${DEPLOY_NAME//_/}"

create_private_s3_bucket() {
    echo "📂 Creating private S3 bucket: $S3_BUCKET_NAME"
    aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region eu-west-2 --create-bucket-configuration LocationConstraint=eu-west-2
    aws s3api put-public-access-block --bucket "$S3_BUCKET_NAME" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    aws s3api put-bucket-encryption --bucket "$S3_BUCKET_NAME" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    echo "✅ S3 bucket $S3_BUCKET_NAME created and secured."
}

delete_private_s3_bucket() {
    echo "🗑 Deleting S3 bucket: $S3_BUCKET_NAME"
    aws s3 rm "s3://$S3_BUCKET_NAME" --recursive || true
    aws s3api delete-bucket --bucket "$S3_BUCKET_NAME" --region eu-west-2 || true
    echo "✅ S3 bucket $S3_BUCKET_NAME deleted."
}




update_api_gateway_deployments_tfvar() {
  local KEY="$DEPLOY_NAME"
  local ARN="$COGNITO_USER_POOL_ARN"

  if ! grep -q "api_gateway_deployments" "$TFVARS_FILE"; then
    cat >> "$TFVARS_FILE" <<EOF

api_gateway_deployments = {
  $KEY = {
    deployment_name = "$KEY"
    cognito_user_pool_arn = "$ARN"
  }
}
EOF
    echo "✅ Created api_gateway_deployments with $KEY."
    return
  fi

  TMP_FILE=$(mktemp)
  awk -v key="$KEY" -v arn="$ARN" '
    BEGIN { inside = 0; found = 0 }
    /^api_gateway_deployments\s*=\s*{/ { inside = 1 }
    inside && /^\s*}/ && !found {
      print "  " key " = {"
      print "    deployment_name = \"" key "\""
      print "    cognito_user_pool_arn = \"" arn "\""
      print "  }"
      found = 1
    }
    { print }
  ' "$TFVARS_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$TFVARS_FILE"
  echo "✅ Appended $KEY to api_gateway_deployments."
}

remove_api_gateway_deployments_entry() {
  local KEY="$DEPLOY_NAME"
  TMP_FILE=$(mktemp)
  awk -v key="$KEY" '
    BEGIN { inside = 0 }
    {
      if ($0 ~ "^[[:space:]]*" key "[[:space:]]*=") { inside = 1; next }
      if (inside && $0 ~ /^[[:space:]]*}/) { inside = 0; next }
      if (!inside) print
    }
  ' "$TFVARS_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$TFVARS_FILE"
  echo "✅ Removed $KEY from api_gateway_deployments."
}

update_ingress() {
  local ACTION=$1
  local HOST="${DEPLOY_NAME}-api.talansm.com"

  HOST_ENTRY=$(cat <<EOF
    - host: ${HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: backend-${DEPLOY_NAME}
                port:
                  number: 80
EOF
)

  if [[ "$ACTION" == "add" ]]; then
    if ! grep -q "$HOST" "$INGRESS_FILE"; then
      echo "➕ Adding host $HOST to Ingress..."
      awk -v block="$HOST_ENTRY" '/rules:/ && !p { print; print block; p=1; next }1' "$INGRESS_FILE" > "${INGRESS_FILE}.tmp" && mv "${INGRESS_FILE}.tmp" "$INGRESS_FILE"
      echo "✅ Host added."
    else
      echo "ℹ️  Host $HOST already present."
    fi
  else
    echo "➖ Removing host $HOST from Ingress..."

    if command -v yq &>/dev/null; then
      yq -i "del(.spec.rules[] | select(.host == \"$HOST\"))" "$INGRESS_FILE"
      echo "✅ Host $HOST removed using yq."
    else
      echo "⚠️ 'yq' not installed, falling back to sed (may be unsafe)."

      awk -v host="$HOST" '
        $0 ~ "- host: " host { in_block=1; next }
        in_block && $0 ~ "^[[:space:]]*- host:" { in_block=0 }
        !in_block
      ' "$INGRESS_FILE" > "${INGRESS_FILE}.tmp" && mv "${INGRESS_FILE}.tmp" "$INGRESS_FILE"

      # Optional: remove trailing empty lines
      sed -i '/^[[:space:]]*$/d' "$INGRESS_FILE"
      echo "✅ Host $HOST removed using awk fallback."
    fi
  fi


  kubectl apply -f "$INGRESS_FILE"
}

# === 🚀 Run ===

if [[ "$ACTION" == "deploy" ]]; then
  echo "🚀 Starting deploy for $DEPLOY_NAME..."

  update_api_gateway_deployments_tfvar
  create_db_via_bastion
  create_private_s3_bucket
  mkdir -p "$DEPLOY_DIR"
  cp "$TEMPLATE_DIR"/*.yaml "$DEPLOY_DIR"

  for file in "$DEPLOY_DIR"/*.yaml; do
    sed -i "s|{{DEPLOY_NAME}}|$DEPLOY_NAME|g" "$file"
    sed -i "s|{{IMAGE_TAG}}|$IMAGE_TAG|g" "$file"
    sed -i "s|{{SPRING_DATASOURCE_USERNAME}}|$DB_USER|g" "$file"
    sed -i "s|{{SERVER_PORT}}|8080|g" "$file"
    sed -i "s|{{COGNITO_USER_POOL_ID}}|$USER_POOL_ID|g" "$file"
    sed -i "s|{{COGNITO_CLIENT_ID}}|$CLIENT_ID|g" "$file"
    sed -i "s|{{COGNITO_REGION}}|$COGNITO_REGION|g" "$file"
    sed -i "s|{{COGNITO_ISSUER_URI}}|$COGNITO_ISSUER|g" "$file"
    sed -i "s|{{S3_BUCKET_NAME}}|$S3_BUCKET_NAME|g" "$file"
  done

  kubectl apply -f "$DEPLOY_DIR"
  update_ingress add
  

  echo "✅ Deployment '$DEPLOY_NAME' applied."

elif [[ "$ACTION" == "delete" ]]; then
  echo "🗑 Starting delete for $DEPLOY_NAME..."

  remove_api_gateway_deployments_entry
  drop_db_via_bastion
  delete_private_s3_bucket
  if [ -d "$DEPLOY_DIR" ]; then
    kubectl delete -f "$DEPLOY_DIR" --ignore-not-found || true
    rm -rf "$DEPLOY_DIR"
  else
    echo "⚠️ Deployment dir $DEPLOY_DIR not found, skipping kubectl delete and rm."
  fi

  update_ingress remove

  echo "✅ Deployment '$DEPLOY_NAME' deleted."
fi
