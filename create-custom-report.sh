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

if [ -z "$TOKEN" ]; then
  TOKEN=$(gcloud auth print-access-token)
fi

echo "Creating Custom Report (llm-budget-and-cost-analysis)..."
echo "Note: This may fail if you haven't sent any test traffic yet or if the analytics pipeline hasn't processed it (takes ~10 mins)."

RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/report_response.json -X POST \
  "https://apigee.googleapis.com/v1/organizations/$PROJECT/reports" \
  --header "Authorization: Bearer $TOKEN" \
  --header 'Accept: application/json' \
  --header 'Content-Type: application/json' \
  --data '{"name":"llm-budget-and-cost-analysis","displayName":"LLM Budget and Cost Analysis","metrics":[{"name":"dc_llm_transaction_cost_v2","function":"sum"},{"name":"dc_llm_prompt_tokens","function":"sum"},{"name":"dc_llm_candidates_tokens","function":"sum"}],"dimensions":["api_product","developer_app","dc_llm_provider","dc_llm_model"],"properties":[{"value":[{}]}],"chartType":"column"}')

if [ "$RESPONSE" -eq 201 ] || [ "$RESPONSE" -eq 200 ]; then
  echo "Custom Report created successfully!"
elif [ "$RESPONSE" -eq 409 ]; then
  echo "Custom Report already exists."
else
  echo "Failed to create Custom Report. HTTP Status: $RESPONSE"
  echo "Error details:"
  cat /tmp/report_response.json
  echo ""
  echo "If the error says the fields are 'not present in schema', please send some test requests to the proxy,"
  echo "wait 10 minutes for the analytics pipeline to register the new fields, and run this script again."
fi

rm -f /tmp/report_response.json
