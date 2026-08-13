#!/bin/bash

# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ ! -f "${SCRIPT_DIR}/env.sh" ]; then
  echo "env.sh not found. Please create it by copying env.sh.template and filling in the values."
  exit 1
fi

source "${SCRIPT_DIR}/env.sh"

if [ -z "$PROJECT" ]; then
  echo "No PROJECT variable set in env.sh"
  exit 1
fi

if [ -z "$APIGEE_ENV" ]; then
  echo "No APIGEE_ENV variable set in env.sh"
  exit 1
fi

if [ -z "$APIGEE_HOST" ]; then
  echo "No APIGEE_HOST variable set in env.sh"
  exit 1
fi

if [ -z "$TOKEN" ]; then
  TOKEN=$(gcloud auth print-access-token)
fi

echo "Installing apigeecli..."
if ! command -v apigeecli &> /dev/null; then
    curl -L https://raw.githubusercontent.com/apigee/apigeecli/main/downloadLatest.sh | sh -
fi
export PATH=$PATH:$HOME/.apigeecli/bin

SA_NAME="apigee-llm-budget-sa"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

echo "Creating Service Account ${SA_EMAIL} if necessary..."
if ! gcloud iam service-accounts describe "${SA_EMAIL}" --project "$PROJECT" &>/dev/null; then
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name "Apigee LLM Budget Control Service Account" \
    --project "$PROJECT"
  echo "Waiting for SA propagation..."
  sleep 5
fi

echo "Granting Vertex AI User role to ${SA_EMAIL}..."
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/aiplatform.user" \
  --quiet >/dev/null

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT}" --format="value(projectNumber)")
APIGEE_SA="service-${PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com"

echo "Granting Token Creator role to Apigee Service Agent on ${SA_EMAIL}..."
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --member="serviceAccount:${APIGEE_SA}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project "$PROJECT" \
  --quiet >/dev/null

echo "Deleting existing KVMs if they exist to ensure a clean import..."
apigeecli kvms delete --name llm-model-costs --env "$APIGEE_ENV" --org "$PROJECT" --token "$TOKEN" || true
apigeecli kvms delete --name llm-provider-config --env "$APIGEE_ENV" --org "$PROJECT" --token "$TOKEN" || true
# We do not need to create them here; apigeecli kvms import will automatically create them.

echo "Importing KVM entries..."
# Prepare KVM files with env name and project ID
KVM_COSTS_FILE="${SCRIPT_DIR}/config/env__${APIGEE_ENV}__llm-model-costs__kvmfile__0.json"
KVM_ROUTING_FILE="${SCRIPT_DIR}/config/env__${APIGEE_ENV}__llm-provider-config__kvmfile__0.json"

cp "${SCRIPT_DIR}/config/env__envname__llm-model-costs__kvmfile__0.json" "$KVM_COSTS_FILE"
cp "${SCRIPT_DIR}/config/env__envname__llm-provider-config__kvmfile__0.json" "$KVM_ROUTING_FILE"

# Replace VERTEXAI_PROJECT_ID and VERTEXAI_REGION with actual values
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s/VERTEXAI_PROJECT_ID/${PROJECT}/g" "$KVM_ROUTING_FILE"
  sed -i '' "s/VERTEXAI_REGION/${REGION}/g" "$KVM_ROUTING_FILE"
else
  sed -i "s/VERTEXAI_PROJECT_ID/${PROJECT}/g" "$KVM_ROUTING_FILE"
  sed -i "s/VERTEXAI_REGION/${REGION}/g" "$KVM_ROUTING_FILE"
fi

# Import
apigeecli kvms import -f "$KVM_COSTS_FILE" --org "$PROJECT" --token "$TOKEN"
apigeecli kvms import -f "$KVM_ROUTING_FILE" --org "$PROJECT" --token "$TOKEN"

# Clean up temporary KVM files
rm "$KVM_COSTS_FILE"
rm "$KVM_ROUTING_FILE"

echo "Creating Data Collectors..."
apigeecli datacollectors create -d "LLM Provider" -n dc_llm_provider -p STRING --org "$PROJECT" --token "$TOKEN" || true
apigeecli datacollectors create -d "LLM Model" -n dc_llm_model -p STRING --org "$PROJECT" --token "$TOKEN" || true
apigeecli datacollectors create -d "LLM Prompt Tokens" -n dc_llm_prompt_tokens -p INTEGER --org "$PROJECT" --token "$TOKEN" || true
apigeecli datacollectors create -d "LLM Candidates Tokens" -n dc_llm_candidates_tokens -p INTEGER --org "$PROJECT" --token "$TOKEN" || true
apigeecli datacollectors create -d "LLM Transaction Cost" -n dc_llm_transaction_cost -p STRING --org "$PROJECT" --token "$TOKEN" || true
apigeecli datacollectors create -d "LLM Transaction Cost V2" -n dc_llm_transaction_cost_v2 -p FLOAT --org "$PROJECT" --token "$TOKEN" || true

echo "Creating Custom Report...."
# Ignore error if report already exists
echo "Attempting to create Custom Report...."
# Ignore error if report already exists or if schema is not ready yet
curl -s -X POST \
  "https://apigee.googleapis.com/v1/organizations/$PROJECT/reports" \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Accept: application/json' \
  --header 'Content-Type: application/json' \
  --data '{"name":"llm-budget-and-cost-analysis","displayName":"LLM Budget and Cost Analysis","metrics":[{"name":"dc_llm_transaction_cost_v2","function":"sum"},{"name":"dc_llm_prompt_tokens","function":"sum"},{"name":"dc_llm_candidates_tokens","function":"sum"}],"dimensions":["api_product","developer_app","dc_llm_provider","dc_llm_model"],"properties":[{"value":[{}]}],"chartType":"column"}' \
  > /dev/null || true
echo "Note: If the Custom Report creation failed (silent in this script), it is because the new Data Collectors"
echo "need to receive traffic first. You can run 'bash create-custom-report.sh' in 10 minutes after sending"
echo "some test requests."

echo "Deploying Shared Flow (SF-LLM-Cost-Quota)..."
SF_REV=$(apigeecli sharedflows create bundle -f "${SCRIPT_DIR}/sharedflowbundle" -n SF-LLM-Cost-Quota --org "$PROJECT" --token "$TOKEN" --disable-check | jq ."revision" -r)
apigeecli sharedflows deploy --name SF-LLM-Cost-Quota --ovr --rev "$SF_REV" --org "$PROJECT" --env "$APIGEE_ENV" --token "$TOKEN"

echo "Deploying Example Proxy (llm-budget-control)..."
PROXY_REV=$(apigeecli apis create bundle -f "${SCRIPT_DIR}/example-proxy/apiproxy" -n llm-budget-control --org "$PROJECT" --token "$TOKEN" --disable-check | jq ."revision" -r)
apigeecli apis deploy --wait --name llm-budget-control --ovr --rev "$PROXY_REV" --org "$PROJECT" --env "$APIGEE_ENV" --token "$TOKEN" --sa "$SA_EMAIL"

echo "Creating Demo Developers..."
apigeecli developers create --user marketing-lead --email marketing-lead@acme.com --first Marketing --last Lead --org "$PROJECT" --token "$TOKEN" || true
apigeecli developers create --user engineering-lead --email engineering-lead@acme.com --first Engineering --last Lead --org "$PROJECT" --token "$TOKEN" || true

echo "Creating Demo API Products..."
# Marketing Product: $0.02 budget (20,000 micro-dollars)
apigeecli products create --name llm-budget-marketing-product \
  --display-name "LLM Budget Marketing Product" \
  --envs "$APIGEE_ENV" \
  --proxies "llm-budget-control" \
  --approval auto \
  --attrs "budget_limit_micro_dollars=20000,budget_interval=1,budget_timeunit=month" \
  --org "$PROJECT" \
  --token "$TOKEN" || true

# Engineering Product: $1.00 budget (1,000,000 micro-dollars)
apigeecli products create --name llm-budget-engineering-product \
  --display-name "LLM Budget Engineering Product" \
  --envs "$APIGEE_ENV" \
  --proxies "llm-budget-control" \
  --approval auto \
  --attrs "budget_limit_micro_dollars=1000000,budget_interval=1,budget_timeunit=month" \
  --org "$PROJECT" \
  --token "$TOKEN" || true

echo "Creating Demo Developer Apps..."
apigeecli apps create --name llm-budget-marketing-app --email marketing-lead@acme.com --prods llm-budget-marketing-product --org "$PROJECT" --token "$TOKEN" --disable-check || true
apigeecli apps create --name llm-budget-engineering-app --email engineering-lead@acme.com --prods llm-budget-engineering-product --org "$PROJECT" --token "$TOKEN" --disable-check || true

MARKETING_KEY=$(apigeecli apps get --name llm-budget-marketing-app --org "$PROJECT" --token "$TOKEN" --disable-check | jq .'[0].credentials[0].consumerKey' -r)
ENGINEERING_KEY=$(apigeecli apps get --name llm-budget-engineering-app --org "$PROJECT" --token "$TOKEN" --disable-check | jq .'[0].credentials[0].consumerKey' -r)

# Save keys to a temp env file for the traffic script
echo "export MARKETING_KEY=\"$MARKETING_KEY\"" > "${SCRIPT_DIR}/demo-keys.env"
echo "export ENGINEERING_KEY=\"$ENGINEERING_KEY\"" >> "${SCRIPT_DIR}/demo-keys.env"

echo " "
echo "================================================================="
echo "Deployment Complete!"
echo "================================================================="
echo "Marketing App Key: $MARKETING_KEY (Budget: \$0.02/month)"
echo "Engineering App Key: $ENGINEERING_KEY (Budget: \$1.00/month)"
echo "Your Proxy URL is: https://${APIGEE_HOST}/v2/samples/llm-budget-control"
echo " "
echo "Keys saved to: ${SCRIPT_DIR}/demo-keys.env"
echo " "
echo "You can test the demo scenario by opening the interactive notebook:"
echo "  llm_budget_control_demo.ipynb"
echo "Or follow the step-by-step guide in the README.md."
echo " "
echo "To view the Custom Report:"
echo "  1. Send some test requests (via the notebook or README instructions)."
echo "  2. Wait ~10 minutes for the analytics pipeline to process the data."
echo "  3. Run the report creation script: bash create-custom-report.sh"
echo "  4. View the report in the Apigee UI under Analyze -> Custom Reports."
echo "================================================================="
