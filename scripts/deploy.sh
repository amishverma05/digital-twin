#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}          # dev | test | prod
PROJECT_NAME=${2:-twin}

echo "🚀 Deploying ${PROJECT_NAME} to ${ENVIRONMENT}..."

# -------------------------------------------------
# 1. Build Lambda package
# -------------------------------------------------
cd "$(dirname "$0")/.."        # project root
echo "📦 Building Lambda package..."
(cd backend && uv run deploy.py)

# -------------------------------------------------
# 2. Terraform init + apply (S3 backend ONLY)
# -------------------------------------------------
cd terraform

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}

echo "🔧 Initializing Terraform backend (S3 only)..."
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="encrypt=true"

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace new "$ENVIRONMENT"
else
  terraform workspace select "$ENVIRONMENT"
fi

# -------------------------------------------------
# 3. Validate Gemini API key
# -------------------------------------------------
if [ -z "$TF_VAR_gemini_api_key" ]; then
  echo "❌ ERROR: TF_VAR_gemini_api_key is not set"
  exit 1
fi

# -------------------------------------------------
# 4. Terraform apply
# -------------------------------------------------
echo "🎯 Applying Terraform..."

if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
  terraform apply \
    -var-file=prod.tfvars \
    -var="project_name=$PROJECT_NAME" \
    -var="environment=$ENVIRONMENT" \
    -var="gemini_api_key=$TF_VAR_gemini_api_key" \
    -auto-approve
else
  terraform apply \
    -var="project_name=$PROJECT_NAME" \
    -var="environment=$ENVIRONMENT" \
    -var="gemini_api_key=$TF_VAR_gemini_api_key" \
    -auto-approve
fi

# -------------------------------------------------
# 5. Build + deploy frontend
# -------------------------------------------------
API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)

cd ../frontend
echo "📝 Setting API URL..."
echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.production

npm install
npm run build
aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
cd ..

# -------------------------------------------------
# 6. Done
# -------------------------------------------------
echo -e "\n✅ Deployment complete!"
echo "📡 API Gateway : $API_URL"
echo "🌐 CloudFront  : $(terraform -chdir=terraform output -raw cloudfront_url)"
