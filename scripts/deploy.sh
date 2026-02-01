#!/bin/bash
set -euo pipefail

ENVIRONMENT="${1:-dev}"        # dev | test | prod
PROJECT_NAME="twin"

echo "🚀 Deploying ${PROJECT_NAME} to ${ENVIRONMENT}..."

# -------------------------
# Sanity checks
# -------------------------
if [[ -z "${TF_VAR_gemini_api_key:-}" ]]; then
  echo "❌ ERROR: TF_VAR_gemini_api_key is not set"
  echo "👉 This must come from GitHub Actions secrets"
  exit 1
fi

if [[ -z "${DEFAULT_AWS_REGION:-}" ]]; then
  echo "❌ ERROR: DEFAULT_AWS_REGION is not set"
  exit 1
fi

# -------------------------
# Build Lambda package
# -------------------------
cd "$(dirname "$0")/.."   # project root
echo "📦 Building Lambda package..."
(cd backend && uv run deploy.py)

# -------------------------
# Terraform init + apply
# -------------------------
cd terraform

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="$DEFAULT_AWS_REGION"

echo "🧱 Initializing Terraform backend (S3)..."

terraform init -reconfigure -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="encrypt=true"

# Workspace handling
if terraform workspace list | grep -q " ${ENVIRONMENT}$"; then
  terraform workspace select "${ENVIRONMENT}"
else
  terraform workspace new "${ENVIRONMENT}"
fi

echo "🎯 Applying Terraform..."

terraform apply -auto-approve \
  -var="project_name=${PROJECT_NAME}" \
  -var="environment=${ENVIRONMENT}"

# -------------------------
# Fetch outputs
# -------------------------
API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)

# -------------------------
# Build & deploy frontend
# -------------------------
cd ../frontend

echo "📝 Writing frontend env..."
echo "NEXT_PUBLIC_API_URL=${API_URL}" > .env.production

npm ci
npm run build

echo "☁️ Uploading frontend to S3..."
aws s3 sync ./out "s3://${FRONTEND_BUCKET}/" --delete

cd ..

# -------------------------
# Done
# -------------------------
echo
echo "✅ Deployment complete!"
echo "📡 API Gateway : ${API_URL}"
echo "🪣 Frontend S3 : ${FRONTEND_BUCKET}"
