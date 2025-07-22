#!/bin/bash
set -e

# 📁 Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
DEPLOYMENTS_DIR="${SCRIPT_DIR}/deployments"
CONFIG_DIR="${SCRIPT_DIR}/../deployments-config"
COGNITO_CONFIG_DIR="${SCRIPT_DIR}/../cognito-config"
INGRESS_FILE="${SCRIPT_DIR}/ingress.yaml"
TFVARS_FILE="${SCRIPT_DIR}/../../integration.tfvars"
LOGO_DIR="${SCRIPT_DIR}/logos"

mkdir -p "$LOGO_DIR" "$CONFIG_DIR" "$COGNITO_CONFIG_DIR"

ACTION=$1
CONFIG_FILE=$2

if [ -z "$ACTION" ] || [ -z "$CONFIG_FILE" ]; then
  echo "❌ Usage: $0 <deploy|delete> <config-file>.json"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "❌ 'jq' is required but not installed."
  exit 1
fi

CONFIG_PATH="$CONFIG_DIR/$CONFIG_FILE"
DEPLOY_NAME=""

if [ ! -f "$CONFIG_PATH" ]; then
  if [ "$ACTION" == "delete" ]; then
    echo "⚠️ Config file missing locally, continuing with deletion: $CONFIG_FILE"
    DEPLOY_NAME="${CONFIG_FILE%.json}"
  else
    echo "❌ Deployment config not found at $CONFIG_PATH"
    exit 1
  fi
else
  DEPLOY_NAME=$(jq -r '.deploy_name' "$CONFIG_PATH")
fi

IMAGE_TAG="5807ed1c"


create_cognito_resources() {
  echo "🔐 Creating Cognito User Pool..."

  POOL_NAME="frontend-pool-$DEPLOY_NAME"
  CLIENT_NAME="frontend-client-$DEPLOY_NAME"
  DOMAIN_PREFIX="frontend-$DEPLOY_NAME"
  CONFIG_PATH="${COGNITO_CONFIG_DIR}/${DEPLOY_NAME}.json"

  USER_POOL_ID=$(aws cognito-idp create-user-pool \
    --pool-name "$POOL_NAME" \
    --schema Name=role,AttributeDataType=String,Mutable=true,Required=false \
    --admin-create-user-config AllowAdminCreateUserOnly=true \
    --lambda-config PreTokenGeneration="arn:aws:lambda:eu-west-2:619403130511:function:LambdaTrigger" \
    --query 'UserPool.Id' --output text)


  USER_POOL_ARN=$(aws cognito-idp describe-user-pool \
    --user-pool-id "$USER_POOL_ID" \
    --query 'UserPool.Arn' --output text)

  aws cognito-idp create-user-pool-domain \
    --domain "$DOMAIN_PREFIX" \
    --user-pool-id "$USER_POOL_ID"

  LOGO_FILE="${LOGO_DIR}/${DEPLOY_NAME}.png"
  CSS_FILE="$SCRIPT_DIR/cognito-style/style.css"
  if aws s3 cp "s3://scheme-management-qa-deployments/${DEPLOY_NAME}.png" "$LOGO_FILE"; then
    echo "✅ Logo downloaded: $LOGO_FILE"
    WIN_LOGO_FILE=$(cygpath -w "$LOGO_FILE" 2>/dev/null || echo "$LOGO_FILE")
    CSS_ESCAPED=$(sed ':a;N;$!ba;s/\n/\\n/g' "$CSS_FILE")
    aws cognito-idp set-ui-customization \
      --user-pool-id "$USER_POOL_ID" \
      --client-id "ALL" \
      --image-file fileb://"$WIN_LOGO_FILE" \
      --css "$CSS_ESCAPED"


  else
    echo "ℹ️ No logo found for $DEPLOY_NAME. Skipping Hosted UI logo upload."
  fi

  REGION=$(aws configure get region)
  REDIRECT_URI="https://${DEPLOY_NAME}.talansm.com/callback"
  HOSTED_UI_URL="https://${DOMAIN_PREFIX}.auth.${REGION}.amazoncognito.com"

  CLIENT_ID=$(aws cognito-idp create-user-pool-client \
    --user-pool-id "$USER_POOL_ID" \
    --client-name "$CLIENT_NAME" \
    --allowed-o-auth-flows "code" \
    --allowed-o-auth-scopes "phone" "email" "openid" "profile" \
    --callback-urls "$REDIRECT_URI" \
    --logout-urls "$REDIRECT_URI" \
    --supported-identity-providers "COGNITO" \
    --prevent-user-existence-errors ENABLED \
    --allowed-o-auth-flows-user-pool-client \
    --explicit-auth-flows "ALLOW_USER_SRP_AUTH" "ALLOW_REFRESH_TOKEN_AUTH" \
    --query 'UserPoolClient.ClientId' --output text)

 # === New user creation with custom role ===
  echo "👤 Creating user wael.arfaoui@talan.com with role SCHEME_ADMIN..."
  aws cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "wael.arfaoui@talan.com" \
    --user-attributes Name=email,Value="wael.arfaoui@talan.com" Name=email_verified,Value=true Name=custom:role,Value=SCHEME_ADMIN \
    --message-action SUPPRESS

  echo "✉️ Sending temporary password email..."
  aws cognito-idp admin-reset-user-password \
    --user-pool-id "$USER_POOL_ID" \
    --username "wael.arfaoui@talan.com"

  cat > "$CONFIG_PATH" <<EOF
{
  "cognito_user_pool_id": "$USER_POOL_ID",
  "cognito_client_id": "$CLIENT_ID",
  "cognito_region": "$REGION",
  "cognito_issuer_uri": "https://cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}",
  "cognito_user_pool_arn": "$USER_POOL_ARN"
}
EOF

  echo "✅ Cognito config saved to $CONFIG_PATH"

  echo "$USER_POOL_ID|$CLIENT_ID|$REGION|$HOSTED_UI_URL|$REDIRECT_URI|$USER_POOL_ARN"
}

delete_cognito_resources() {
  echo "🧽 Deleting Cognito resources..."
  DOMAIN_PREFIX="frontend-$DEPLOY_NAME"
  USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 60 \
    --query "UserPools[?Name=='frontend-pool-${DEPLOY_NAME}'].Id" --output text)

  if [[ -n "$USER_POOL_ID" ]]; then
    aws cognito-idp delete-user-pool-domain --domain "$DOMAIN_PREFIX" --user-pool-id "$USER_POOL_ID" || true
    aws cognito-idp delete-user-pool --user-pool-id "$USER_POOL_ID" || true
    echo "✅ Cognito User Pool $USER_POOL_ID deleted."
  else
    echo "⚠️ No Cognito User Pool found for $DEPLOY_NAME"
  fi

  CONFIG_PATH="${COGNITO_CONFIG_DIR}/${DEPLOY_NAME}.json"
  if [ -f "$CONFIG_PATH" ]; then
    rm -f "$CONFIG_PATH"
    echo "🗑️ Deleted Cognito config file $CONFIG_PATH"
  fi
}

add_subdomain_to_tfvars() {
  KEY="$DEPLOY_NAME"
  FILE="$TFVARS_FILE"

  if ! grep -q "^frontend_subdomains\s*=" "$FILE"; then
    echo -e "\nfrontend_subdomains = {\n  $KEY = true\n}" >> "$FILE"
    echo "✅ Created frontend_subdomains block with $KEY."
    return
  fi

  if sed -n '/^frontend_subdomains\s*=/,/}/p' "$FILE" | grep -q "^\s*$KEY\s*="; then
    echo "⚠️ $KEY already exists in frontend_subdomains."
    return
  fi

  TMP_FILE=$(mktemp)
  awk -v key="$KEY" '
    BEGIN { added = 0 }
    /^frontend_subdomains\s*=/ { in_block = 1 }
    in_block && /^\s*}/ && !added {
      print "  " key " = true"
      added = 1
    }
    { print }
  ' "$FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$FILE"

  echo "✅ Added $KEY to frontend_subdomains."
}

remove_subdomain_from_tfvars() {
  KEY="$DEPLOY_NAME"
  FILE="$TFVARS_FILE"
  sed -i.bak "/^frontend_subdomains\s*=/,/}/ { /^\s*$KEY\s*=/d }" "$FILE"
  echo "🧹 Removed $KEY from frontend_subdomains."
}

clean_ingress_rule() {
  HOST="${DEPLOY_NAME}.talansm.com"
  if grep -q "^[[:space:]]*-[[:space:]]*host:[[:space:]]*${HOST}" "$INGRESS_FILE"; then
    sed -i.bak -e "/^[[:space:]]*-[[:space:]]*host:[[:space:]]*${HOST}/,/^[[:space:]]*-[[:space:]]*host:/{
      /^[[:space:]]*-[[:space:]]*host:[[:space:]]*${HOST}/d
      /^[[:space:]]*-[[:space:]]*host:/!d
    }" "$INGRESS_FILE"
    kubectl apply -f "$INGRESS_FILE"
    echo "✅ Ingress updated after removing host ${HOST}."
  else
    echo "ℹ️ No ingress rule found for ${HOST}."
  fi
}

# 🚀 DEPLOY
if [ "$ACTION" == "deploy" ]; then
  COGNITO_CONFIG_PATH="${COGNITO_CONFIG_DIR}/${DEPLOY_NAME}.json"
  if [ -f "$COGNITO_CONFIG_PATH" ]; then
    COGNITO_USER_POOL_ID=$(jq -r '.cognito_user_pool_id' "$COGNITO_CONFIG_PATH")
    COGNITO_CLIENT_ID=$(jq -r '.cognito_client_id' "$COGNITO_CONFIG_PATH")
    COGNITO_REGION=$(jq -r '.cognito_region' "$COGNITO_CONFIG_PATH")
    COGNITO_USER_POOL_ARN=$(jq -r '.cognito_user_pool_arn' "$COGNITO_CONFIG_PATH")
    COGNITO_HOSTED_UI_URL="https://frontend-$DEPLOY_NAME.auth.${COGNITO_REGION}.amazoncognito.com"
    COGNITO_REDIRECT_URI="https://${DEPLOY_NAME}.talansm.com/callback"
  else
    create_cognito_resources

    COGNITO_CONFIG_PATH="${COGNITO_CONFIG_DIR}/${DEPLOY_NAME}.json"
    COGNITO_USER_POOL_ID=$(jq -r '.cognito_user_pool_id' "$COGNITO_CONFIG_PATH")
    COGNITO_CLIENT_ID=$(jq -r '.cognito_client_id' "$COGNITO_CONFIG_PATH")
    COGNITO_REGION=$(jq -r '.cognito_region' "$COGNITO_CONFIG_PATH")
    COGNITO_USER_POOL_ARN=$(jq -r '.cognito_user_pool_arn' "$COGNITO_CONFIG_PATH")
    COGNITO_HOSTED_UI_URL="https://frontend-${DEPLOY_NAME}.auth.${COGNITO_REGION}.amazoncognito.com"
    COGNITO_REDIRECT_URI="https://${DEPLOY_NAME}.talansm.com/callback"

    echo "✅ COGNITO_USER_POOL_ID: $COGNITO_USER_POOL_ID"
    echo "✅ COGNITO_CLIENT_ID: $COGNITO_CLIENT_ID"
    echo "✅ COGNITO_REGION: $COGNITO_REGION"
    echo "✅ COGNITO_HOSTED_UI_URL: $COGNITO_HOSTED_UI_URL"
    echo "✅ COGNITO_REDIRECT_URI: $COGNITO_REDIRECT_URI"


  fi

  DEPLOY_DIR="$DEPLOYMENTS_DIR/$DEPLOY_NAME"
  mkdir -p "$DEPLOY_DIR"
  BLACK_LOGO_URL="https://${S3_BUCKET}.s3.${COGNITO_REGION}.amazonaws.com/BLACK_LOGO.png"
  WHITE_LOGO_URL="https://${S3_BUCKET}.s3.${COGNITO_REGION}.amazonaws.com/WHITE_LOGO.png"
  COOKIES_URL="https://${S3_BUCKET}.s3.${COGNITO_REGION}.amazonaws.com/cookies.pdf"
  SCHEME_NAME="${DEPLOY_NAME}"

  # Copy all template YAMLs EXCEPT configmap.yaml
  for file in "$TEMPLATE_DIR"/*.yaml; do
    if [[ "$(basename "$file")" != "configmap.yaml" ]]; then
      cp "$file" "$DEPLOY_DIR"
    fi
  done

  # Render configmap.yaml separately with full sed replacements
  sed -e "s|{{DEPLOY_NAME}}|$DEPLOY_NAME|g" \
      -e "s|{{VITE_API_BASE_URL}}|https://${DEPLOY_NAME}-api.talansm.com/api/v1|g" \
      -e "s|{{VITE_COGNITO_CLIENT_ID}}|$COGNITO_CLIENT_ID|g" \
      -e "s|{{VITE_COGNITO_HOSTED_UI_URL}}|$COGNITO_HOSTED_UI_URL|g" \
      -e "s|{{VITE_COGNITO_REDIRECT_URI}}|$COGNITO_REDIRECT_URI|g" \
      -e "s|{{VITE_COGNITO_REGION}}|$COGNITO_REGION|g" \
      -e "s|{{VITE_COGNITO_USER_POOL_ID}}|$COGNITO_USER_POOL_ID|g" \
      -e "s|{{VITE_BLACK_LOGO_URL}}|$BLACK_LOGO_URL|g" \
      -e "s|{{VITE_WHITE_LOGO_URL}}|$WHITE_LOGO_URL|g" \
      -e "s|{{VITE_SCHEME_NAME}}|$SCHEME_NAME|g" \
      -e "s|{{VITE_COOCKIES_FILE_URL}}|$COOKIES_URL|g" \
      "$TEMPLATE_DIR/configmap.yaml" > "$DEPLOY_DIR/configmap.yaml"

 # Now also replace placeholders in other YAML files in $DEPLOY_DIR
  for file in "$DEPLOY_DIR"/*.yaml; do
    sed -i "s|{{DEPLOY_NAME}}|$DEPLOY_NAME|g" "$file"
    sed -i "s|{{IMAGE_TAG}}|$IMAGE_TAG|g" "$file"
    sed -i "s|{{VITE_API_BASE_URL}}|https://${DEPLOY_NAME}-api.talansm.com/|g" "$file"
  done

  add_subdomain_to_tfvars

  if ! grep -q "${DEPLOY_NAME}.talansm.com" "$INGRESS_FILE"; then
    DOMAIN_BLOCK=$(cat <<EOF
    - host: ${DEPLOY_NAME}.talansm.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-${DEPLOY_NAME}
                port:
                  number: 80
EOF
)
    awk -v block="$DOMAIN_BLOCK" '
      /rules:/ && !p { print; print block; p=1; next }1
    ' "$INGRESS_FILE" > "${INGRESS_FILE}.tmp" && mv "${INGRESS_FILE}.tmp" "$INGRESS_FILE"
  fi

  kubectl apply -f "$DEPLOY_DIR"
  kubectl apply -f "$INGRESS_FILE"
  echo "✅ Deployment '$DEPLOY_NAME' complete."

# 🗑️ DELETE
elif [ "$ACTION" == "delete" ]; then
    echo "🗑️ Deleting deployment for $DEPLOY_NAME..."
    DEPLOY_DIR="$DEPLOYMENTS_DIR/$DEPLOY_NAME"
    kubectl delete -f "$DEPLOY_DIR" --ignore-not-found
    clean_ingress_rule
    remove_subdomain_from_tfvars
    delete_cognito_resources

    # Delete downloaded logo
    LOGO_FILE="${LOGO_DIR}/${DEPLOY_NAME}.png"
    if [ -f "$LOGO_FILE" ]; then
      rm -f "$LOGO_FILE"
      echo "🗑️ Deleted logo file $LOGO_FILE"
    fi

    rm -rf "$DEPLOY_DIR"
    echo "✅ Deletion '$DEPLOY_NAME' complete."

else
  echo "❌ Unknown action: $ACTION"
  exit 1
fi
