# LLM Budget Control & Cost Quota

This sample demonstrates how to implement **real-time dollar-based budget control and cost quota** for LLM (Large Language Model) APIs in Apigee.

Unlike token-based limits, this sample calculates the actual financial cost of each transaction (based on input and output token counts and model-specific pricing) and enforces a monthly dollar budget per Developer App.

It is implemented as a **Shared Flow**, making it easily reusable across any API proxy in your Apigee environment.

## Architecture

The solution uses a **Shared Flow** (`SF-LLM-Cost-Quota`) that is called twice during the API proxy lifecycle:

1.  **Request Path (Pre-Flow)**:
    *   Executes the `Quota` policy with a weight of `0`.
    *   This checks if the client's accumulated budget has already been exceeded. If it has, Apigee immediately returns an HTTP `429 Too Many Requests`.
2.  **Response Path (Post-Flow)**:
    *   Extracts the actual token usage (input and output) from the LLM response.
    *   Retrieves the model's unit costs from a Key Value Map (KVM) using the key `{provider}/{model}`.
    *   Calculates the transaction cost in JavaScript.
    *   Converts the cost to **micro-dollars** (to work around Apigee's integer-only quota counters) and updates the `Quota` counter by this weight.
    *   Captures the metrics (provider, model, tokens, cost) using `DataCapture` for custom reports.

### Multi-Provider Support

The Shared Flow is designed to support multiple providers out-of-the-box:
*   **Google Vertex AI**: Extracts from `$.usageMetadata.promptTokenCount` and `$.usageMetadata.candidatesTokenCount`.
*   **OpenAI**: Extracts from `$.usage.prompt_tokens` and `$.usage.completion_tokens`.
*   **Anthropic**: Extracts from `$.usage.input_tokens` and `$.usage.output_tokens`.

---

## Prerequisites

1.  **Apigee X or Apigee Hybrid** environment.
2.  **Google Cloud SDK (gcloud)** installed and authenticated.
3.  **apigeecli** installed (the deployment script will attempt to install it if missing).
4.  **IAM Permissions**: The Apigee runtime service account must have the `Vertex AI User` (`roles/aiplatform.user`) role to call Vertex AI.

---

## Setup and Deployment

1.  Navigate to the sample directory:
    ```bash
    cd llm-budget-control
    ```

2.  Copy `env.sh` and fill in your Apigee details:
    ```bash
    # Edit env.sh and set:
    # PROJECT="your-gcp-project"
    # APIGEE_ENV="your-apigee-env"
    # APIGEE_HOST="your-apigee-virtual-host-domain"
    ```

3.  Run the deployment script:
    ```bash
    bash deploy-llm-budget-control.sh
    ```

This script will:
*   Create two KVMs: `llm-model-costs` and `llm-provider-config`.
*   Import default pricing and routing configurations.
*   Create Data Collectors for analytics.
*   Attempt to create a Custom Report (this may fail silently if no traffic has been sent yet).
*   Deploy the Shared Flow and the Example Proxy.
*   Create Demo Developers (`marketing-lead` and `engineering-lead`).
*   Create Demo API Products with different budgets:
    *   `llm-budget-marketing-product` (Budget: $0.006/month)
    *   `llm-budget-engineering-product` (Budget: $1.00/month)
*   Create Demo Developer Apps (`llm-budget-marketing-app` and `llm-budget-engineering-app`).
*   Output the API Keys and save them to `demo-keys.env`.

---

## Testing the Sample (Interactive Demo Scenarios)

The deployment script outputs the API keys for both the Marketing and Engineering apps, and saves them to `demo-keys.env`.

You can run these scenarios manually using `curl` to observe the budget and tenant isolation behavior. This mirrors the walkthrough in the [llm_budget_control_demo.ipynb](./llm_budget_control_demo.ipynb) notebook.

Before starting, source the environment variables:
```bash
source env.sh
source demo-keys.env
```

### Step 1: Engineering Team (Succeeds)
The Engineering team has a budget of **$1.00** (1,000,000 micro-dollars). We send a request to a relatively expensive model (`gemini-2.5-pro`).

```bash
curl -i -X POST "https://${APIGEE_HOST}/v2/samples/llm-budget-control/v1/projects/${PROJECT}/locations/${REGION:-us-west1}/publishers/google/models/gemini-2.5-pro:generateContent" \
  -H "x-apikey: ${ENGINEERING_KEY}" \
  -H "x-llm-provider: google" \
  -H "Content-Type: application/json" \
  -d '{ "contents": [{ "role": "user", "parts": [{ "text": "Explain quantum computing in one sentence." }] }] }'
```
*   **Expected Result**: `200 OK`.
*   **Headers to check**:
    *   `x-llm-input-tokens`: ~7
    *   `x-llm-output-tokens`: ~15-30
    *   `x-llm-model-cost-micro-dollars`: Cost of the request (e.g. ~400 micro-dollars).
    *   `x-llm-remaining-budget-micro-dollars`: ~999,600 micro-dollars remaining.

---

### Step 2: Marketing Team - First Request (Succeeds)
The Marketing team has a small budget of **$0.006** (6,000 micro-dollars). We send a request to `gemini-2.5-pro` with the thinking budget set to the minimum of `128` tokens to keep the demo costs predictable (since thinking cannot be completely disabled for Gemini 2.5 Pro).

```bash
curl -i -X POST "https://${APIGEE_HOST}/v2/samples/llm-budget-control/v1/projects/${PROJECT}/locations/${REGION:-us-west1}/publishers/google/models/gemini-2.5-pro:generateContent" \
  -H "x-apikey: ${MARKETING_KEY}" \
  -H "x-llm-provider: google" \
  -H "Content-Type: application/json" \
  -d '{ "contents": [{ "role": "user", "parts": [{ "text": "Write a catchy slogan for a new solar watch." }] }], "generationConfig": { "thinkingConfig": { "thinkingBudget": 128 } } }'
```
*   **Expected Result**: `200 OK`.
*   **Headers to check**:
    *   `x-llm-model-cost-micro-dollars`: Cost of the request.
    *   `x-llm-remaining-budget-micro-dollars`: The remaining budget will be reduced (e.g. to ~2,000 micro-dollars).

---

### Step 3: Marketing Team - Second Request (Succeeds, but exhausts budget)
We send a second, larger request for the Marketing team. This request will ask for a longer response (with the thinking budget set to `128` tokens), which will cost more and exhaust the remaining budget.

```bash
curl -i -X POST "https://${APIGEE_HOST}/v2/samples/llm-budget-control/v1/projects/${PROJECT}/locations/${REGION:-us-west1}/publishers/google/models/gemini-2.5-pro:generateContent" \
  -H "x-apikey: ${MARKETING_KEY}" \
  -H "x-llm-provider: google" \
  -H "Content-Type: application/json" \
  -d '{ "contents": [{ "role": "user", "parts": [{ "text": "Write a 500-word newsletter about the benefits of solar energy." }] }], "generationConfig": { "thinkingConfig": { "thinkingBudget": 128 } } }'
```
*   **Expected Result**: `200 OK`.
*   **Headers to check**:
    *   `x-llm-remaining-budget-micro-dollars`: This will drop below `0` (or close to it) because the cost exceeded the remaining budget. Apigee allows the *current* transaction to complete, but future transactions will be blocked.

---

### Step 4: Marketing Team - Third Request (Blocked)
Now that the Marketing team's budget is exhausted, any subsequent requests will be blocked immediately at the Apigee gateway before calling the LLM.

```bash
curl -i -X POST "https://${APIGEE_HOST}/v2/samples/llm-budget-control/v1/projects/${PROJECT}/locations/${REGION:-us-west1}/publishers/google/models/gemini-2.5-flash:generateContent" \
  -H "x-apikey: ${MARKETING_KEY}" \
  -H "x-llm-provider: google" \
  -H "Content-Type: application/json" \
  -d '{ "contents": [{ "role": "user", "parts": [{ "text": "Explain the greenhouse effect in one paragraph." }] }] }'
```
*   **Expected Result**: `429 Too Many Requests`.
*   **Response Body**:
    ```json
    {
      "fault": {
        "faultstring": "Quota violation error. Register Resource Limit exceeded...",
        "detail": {
          "code": "policies.ratelimit.QuotaViolation"
        }
      }
    }
    ```

---

### Step 5: Tenant Isolation (Engineering Still Works)
To verify that the quota is enforced per-app (tenant isolation), we send a request using the Engineering team's key. Since they have their own budget and plenty of it left, their request succeeds.

```bash
curl -i -X POST "https://${APIGEE_HOST}/v2/samples/llm-budget-control/v1/projects/${PROJECT}/locations/${REGION:-us-west1}/publishers/google/models/gemini-2.5-flash:generateContent" \
  -H "x-apikey: ${ENGINEERING_KEY}" \
  -H "x-llm-provider: google" \
  -H "Content-Type: application/json" \
  -d '{ "contents": [{ "role": "user", "parts": [{ "text": "Explain the difference between a list and a tuple in Python." }] }] }'
```
*   **Expected Result**: `200 OK`.
*   **Headers to check**:
    *   `x-llm-remaining-budget-micro-dollars`: Will show they still have a healthy budget.

---

### (Optional) Test OpenAI (Simulated/Actual)
If you have configured your OpenAI API Key in the `llm-provider-config` KVM (under `openai__credential`), you can test routing to OpenAI:

```bash
curl -i -X POST "https://${APIGEE_HOST}/v2/samples/llm-budget-control/v1/chat/completions" \
  -H "x-apikey: ${ENGINEERING_KEY}" \
  -H "x-llm-provider: openai" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [
      {
        "role": "user",
        "content": "Hello!"
      }
    ]
  }'
```

---

## Custom Reports & Analytics

Because Apigee Custom Reports require the underlying Data Collectors to have registered schema fields (which only happens after they receive traffic), the custom report may not be created successfully during the initial deployment.

To create and view the Custom Report:

1.  **Send test traffic**: Send a few test requests to the proxy (see [Testing the Sample](#testing-the-sample)).
2.  **Wait**: Wait ~10 minutes for the Apigee analytics pipeline to process the data and register the new Data Collector fields.
3.  **Create the report**: Run the report creation script:
    ```bash
    bash create-custom-report.sh
    ```
4.  **View the report**: Go to the Apigee UI, navigate to **Analyze** -> **Custom Reports**, and select **LLM Budget and Cost Analysis**. You will see a column chart showing the sum of **Transaction Cost**, **Prompt Tokens**, and **Candidates Tokens** grouped by **API Product**, **Developer App**, **Model Provider**, and **Model**.
    *   *Note*: To focus on a specific team or model, you can use the UI filter dropdowns in the report view to filter by **API Product** (e.g., select `llm-budget-engineering-product`), **Developer App**, etc.

---

## Clean Up

To remove all resources created by this sample, run:

```bash
bash clean-up-llm-budget-control.sh
```
