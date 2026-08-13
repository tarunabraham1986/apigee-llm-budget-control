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
  echo "env.sh not found."
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

if [ -z "$TOKEN" ]; then
  TOKEN=$(gcloud auth print-access-token)
fi

export PATH=$PATH:$HOME/.apigeecli/bin

echo "Deleting Developer Apps..."
apigeecli apps delete --name llm-budget-marketing-app --email marketing-lead@acme.com --org "$PROJECT" --token "$TOKEN" || true
apigeecli apps delete --name llm-budget-engineering-app --email engineering-lead@acme.com --org "$PROJECT" --token "$TOKEN" || true

echo "Deleting API Products..."
apigeecli products delete --name llm-budget-marketing-product --org "$PROJECT" --token "$TOKEN" || true
apigeecli products delete --name llm-budget-engineering-product --org "$PROJECT" --token "$TOKEN" || true

echo "Deleting Developers..."
apigeecli developers delete --email marketing-lead@acme.com --org "$PROJECT" --token "$TOKEN" || true
apigeecli developers delete --email engineering-lead@acme.com --org "$PROJECT" --token "$TOKEN" || true

rm -f "${SCRIPT_DIR}/demo-keys.env"

echo "Undeploying and Deleting Example Proxy (llm-budget-control)..."
# We need to find the deployed revision to undeploy it, or we can use apigeecli's ability to undeploy all?
# apigeecli doesn't have "undeploy all", we have to specify revision.
# A simpler way is to use the Apigee API or just delete it (deleting a proxy automatically undeploys it in Apigee X!).
# Yes! Deleting the API proxy resource will automatically undeploy it from all environments.
apigeecli apis delete --name llm-budget-control --org "$PROJECT" --token "$TOKEN" || true

echo "Undeploying and Deleting Shared Flow (SF-LLM-Cost-Quota)..."
# Deleting the shared flow also automatically undeploys it.
apigeecli sharedflows delete --name SF-LLM-Cost-Quota --org "$PROJECT" --token "$TOKEN" || true

echo "Deleting KVMs..."
apigeecli kvms delete --name llm-model-costs --env "$APIGEE_ENV" --org "$PROJECT" --token "$TOKEN" || true
apigeecli kvms delete --name llm-provider-config --env "$APIGEE_ENV" --org "$PROJECT" --token "$TOKEN" || true

echo "Deleting Custom Report..."
curl -s -X DELETE \
  "https://apigee.googleapis.com/v1/organizations/$PROJECT/reports/llm-budget-and-cost-analysis" \
  --header "Authorization: Bearer $TOKEN" \
  > /dev/null || true

echo "Deleting Service Account..."
SA_NAME="apigee-llm-budget-sa"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
gcloud iam service-accounts delete "${SA_EMAIL}" --project "$PROJECT" --quiet || true

echo "Note: Data Collectors cannot be easily deleted if they have captured data. They have been left in the org."
echo "Clean-up Complete!"
