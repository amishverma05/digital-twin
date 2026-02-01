#!/bin/bash
set -e

# -------------------------
# Args
# -------------------------
ENVIRONMENT=${1:-}
PROJECT_NAME=${2:-twin}

if [ -z "$ENVIRONMENT" ]; then
  echo "❌ ERROR: Environment is required"
  echo "Usage: ./destroy.sh <dev|test|prod>"
  exit 1
fi

echo "🗑️ Destroying ${PROJECT_NAME}-${ENVIRONMENT} infrastructure..."

# -------------------------
# REQUIRED ENV VAR CHECKS
# -------------------------
if [ -z "$TF_VAR_gemini_api_key" ]; then
  echo "❌ ERROR: TF_VAR_gemini_api_key is not set"
  exit 1
fi

if [ -z "$DEFAULT_AWS_REGION" ]; then
  echo "❌ ERROR: DEFAULT_AWS_REGION is not set"
  exit 1
fi

# -------------------------
# Move to terraform dir
# -------------------------
cd "$(dirname "$0")/../terraform"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="$DEFAULT_AWS_REGION"

# -------------------------
# Terraform init (S3 backend)
# -------------------------
echo "🔧 Initializing Terraform backend..."

terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="encrypt=true"

# -------------------------
# Workspace handling
# -------------------------
if terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace select "$ENVIRONMENT"
else
  echo "⚠️ Workspace '$ENVIRONMENT' does not exist. Nothing to destroy."
  exit 0
fi

# -------------------------
# Empty S3 buckets (ignore if missing)
# -------------------------
FRONTEND_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"
MEMORY_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-memory-${AWS_ACCOUNT_ID}"

echo "🧹 Cleaning S3 buckets (if they exist)..."

aws s3 rm "s3://${FRONTEND_BUCKET}" --recursive || true
aws s3 rm "s3://${MEMORY_BUCKET}" --recursive || true

# -------------------------
# Dummy lambda zip (required for destroy)
# -------------------------
if [ ! -f "../backend/lambda-deployment.zip" ]; then
  echo "📦 Creating dummy lambda-deployment.zip"
  mkdir -p ../backend
  echo "dummy" | zip -q ../backend/lambda-deployment.zip -
fi

# -------------------------
# Terraform destroy
# -------------------------
echo "🔥 Running terraform destroy..."

terraform destroy \
  -var="project_name=${PROJECT_NAME}" \
  -var="environment=${ENVIRONMENT}" \
  -var="gemini_api_key=${TF_VAR_gemini_api_key}" \
  -auto-approve

echo "✅ Destroy completed for ${ENVIRONMENT}"
