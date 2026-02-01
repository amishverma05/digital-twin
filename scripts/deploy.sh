#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}
PROJECT_NAME="twin"

echo "🚀 Deploying $PROJECT_NAME to $ENVIRONMENT"

cd "$(dirname "$0")/.."

# Build Lambda
echo "📦 Building Lambda package..."
(cd backend && uv run deploy.py)

cd terraform

terraform init -input=false
terraform workspace select "$ENVIRONMENT" || terraform workspace new "$ENVIRONMENT"

# HARD FAIL if missing key
if [ -z "$TF_VAR_gemini_api_key" ]; then
  echo "❌ TF_VAR_gemini_api_key not set"
  exit 1
fi

terraform apply \
  -auto-approve \
  -var="project_name=$PROJECT_NAME" \
  -var="environment=$ENVIRONMENT"

echo "✅ Terraform applied"

API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)

cd ../frontend
echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.production
npm install
npm run build
aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
