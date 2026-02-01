#!/bin/bash
set -e

if [ $# -eq 0 ]; then
  echo "❌ Usage: $0 <environment>"
  exit 1
fi

ENVIRONMENT=$1
PROJECT_NAME=${2:-twin}

echo "🗑️ Destroying ${PROJECT_NAME}-${ENVIRONMENT}..."

cd "$(dirname "$0")/../terraform"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}

echo "🔧 Initializing Terraform backend (S3 only)..."
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="encrypt=true"

terraform workspace select "$ENVIRONMENT"

# -------------------------------------------------
# Empty S3 buckets safely
# -------------------------------------------------
FRONTEND_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"
MEMORY_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-memory-${AWS_ACCOUNT_ID}"

echo "📦 Emptying S3 buckets..."

aws s3 rm "s3://$FRONTEND_BUCKET" --recursive || true
aws s3 rm "s3://$MEMORY_BUCKET" --recursive || true

# -------------------------------------------------
# Dummy Lambda ZIP (required for destroy)
# -------------------------------------------------
if [ ! -f "../backend/lambda-deployment.zip" ]; then
  echo "dummy" | zip ../backend/lambda-deployment.zip -
fi

# -------------------------------------------------
# Terraform destroy
# -------------------------------------------------
echo "🔥 Running terraform destroy..."

terraform destroy \
  -var="project_name=$PROJECT_NAME" \
  -var="environment=$ENVIRONMENT" \
  -auto-approve

echo "✅ Destroy completed for ${ENVIRONMENT}"
