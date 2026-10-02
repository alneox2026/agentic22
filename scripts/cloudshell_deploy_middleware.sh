#!/usr/bin/env bash
set -euo pipefail

# Deploy an isolated middleware stack. The default identity comes from the
# cloned repository directory; set MIDDLEWARE_STACK_NAME explicitly only when
# the directory name is unsuitable.

PROJECT_ID="${PROJECT_ID:-ceo-dev123}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-ceosystem}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

MIDDLEWARE_STACK_NAME="${MIDDLEWARE_STACK_NAME:-$(basename "${ROOT_DIR}")}"
MIDDLEWARE_IMAGE_PREFIX="${MIDDLEWARE_IMAGE_PREFIX:-${MIDDLEWARE_STACK_NAME}}"
FIRESTORE_NAMESPACE="${FIRESTORE_NAMESPACE:-${MIDDLEWARE_STACK_NAME//-/_}}"
# Collection precedence is: explicit environment override, customized
# Terraform variable default, then an isolated namespace-derived fallback for
# the template's *_v3 placeholder defaults. This makes checked-in per-stack
# sharing choices survive Cloud Shell deployments without sacrificing safe
# defaults for fresh template clones.
terraform_variable_default() {
  local variable_name="$1"
  sed -n "/^variable \"${variable_name}\" {/,/^}/p" \
    "${ROOT_DIR}/infra/terraform/variables.tf" \
    | sed -n 's/^[[:space:]]*default[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

resolve_firestore_collection() {
  local environment_name="$1"
  local terraform_name="$2"
  local collection_prefix="$3"
  local environment_value=""
  local terraform_default=""

  if [[ -v "${environment_name}" ]]; then
    environment_value="${!environment_name}"
  fi
  if [[ -n "${environment_value}" ]]; then
    printf '%s' "${environment_value}"
    return
  fi

  terraform_default="$(terraform_variable_default "${terraform_name}")"
  if [[ -n "${terraform_default}" && ! "${terraform_default}" =~ _v3$ ]]; then
    printf '%s' "${terraform_default}"
  else
    printf '%s_%s' "${collection_prefix}" "${FIRESTORE_NAMESPACE}"
  fi
}

FIRESTORE_THREADS_COLLECTION="$(resolve_firestore_collection FIRESTORE_THREADS_COLLECTION firestore_threads_collection agent_threads)"
FIRESTORE_MESSAGES_SUBCOLLECTION="$(resolve_firestore_collection FIRESTORE_MESSAGES_SUBCOLLECTION firestore_messages_subcollection messages)"
FIRESTORE_IDEMPOTENCY_COLLECTION="$(resolve_firestore_collection FIRESTORE_IDEMPOTENCY_COLLECTION firestore_idempotency_collection processed_events)"
FIRESTORE_BILLING_LEDGER_COLLECTION="$(resolve_firestore_collection FIRESTORE_BILLING_LEDGER_COLLECTION firestore_billing_ledger_collection agent_billing_ledger)"
FIRESTORE_CUSTOMER_WALLETS_COLLECTION="$(resolve_firestore_collection FIRESTORE_CUSTOMER_WALLETS_COLLECTION firestore_customer_wallets_collection customer_wallets)"
FIRESTORE_BILLING_RESERVATIONS_COLLECTION="$(resolve_firestore_collection FIRESTORE_BILLING_RESERVATIONS_COLLECTION firestore_billing_reservations_collection billing_reservations)"
FIRESTORE_WALLET_TRANSACTIONS_COLLECTION="$(resolve_firestore_collection FIRESTORE_WALLET_TRANSACTIONS_COLLECTION firestore_wallet_transactions_collection wallet_transactions)"
FIRESTORE_CUSTOMER_BILLING_PERIODS_COLLECTION="$(resolve_firestore_collection FIRESTORE_CUSTOMER_BILLING_PERIODS_COLLECTION firestore_customer_billing_periods_collection customer_billing_periods)"
FIRESTORE_CUSTOMER_BILLING_ACCOUNTS_COLLECTION="$(resolve_firestore_collection FIRESTORE_CUSTOMER_BILLING_ACCOUNTS_COLLECTION firestore_customer_billing_accounts_collection customer_billing_accounts)"
FIRESTORE_STRIPE_WEBHOOK_EVENTS_COLLECTION="$(resolve_firestore_collection FIRESTORE_STRIPE_WEBHOOK_EVENTS_COLLECTION firestore_stripe_webhook_events_collection stripe_webhook_events)"
FIRESTORE_SUBSCRIPTION_CANCELLATION_REQUESTS_COLLECTION="$(resolve_firestore_collection FIRESTORE_SUBSCRIPTION_CANCELLATION_REQUESTS_COLLECTION firestore_subscription_cancellation_requests_collection subscription_cancellation_requests)"
DEPLOYMENT_ENV="${DEPLOYMENT_ENV:-development}"
BILLING_CATALOG_PATH="${BILLING_CATALOG_PATH:-/app/config/billing.prod.yaml}"
ALERT_NOTIFICATION_CHANNELS_JSON="${ALERT_NOTIFICATION_CHANNELS_JSON:-[]}"

case "${DEPLOYMENT_ENV}" in
  development|staging|production) ;;
  *) echo "ERROR: DEPLOYMENT_ENV must be development, staging, or production." >&2; exit 2 ;;
esac

if ! ALERT_NOTIFICATION_CHANNEL_COUNT="$(python3 -c 'import json,sys; value=json.loads(sys.argv[1]); assert isinstance(value,list) and all(isinstance(item,str) and item.strip() for item in value); print(len(value))' "${ALERT_NOTIFICATION_CHANNELS_JSON}" 2>/dev/null)"; then
  echo "ERROR: ALERT_NOTIFICATION_CHANNELS_JSON must be a JSON array of Cloud Monitoring channel resource names." >&2
  exit 2
fi

if [ "${DEPLOYMENT_ENV}" = "production" ]; then
  case "${BILLING_CATALOG_PATH}" in
    /app/*) BILLING_CATALOG_FILE="${ROOT_DIR}/${BILLING_CATALOG_PATH#/app/}" ;;
    *) echo "ERROR: Production BILLING_CATALOG_PATH must point to a file under /app in the image." >&2; exit 2 ;;
  esac
  if [ ! -f "${BILLING_CATALOG_FILE}" ] || ! grep -Eq '^[[:space:]]*stripe_mode:[[:space:]]*live([[:space:]]*(#.*)?)?$' "${BILLING_CATALOG_FILE}"; then
    echo "ERROR: Production requires a billing catalog with stripe_mode: live. Update the live Stripe catalog before deploying." >&2
    exit 2
  fi
  if grep -Eq 'ceo-dev123|281577273798' "${ROOT_DIR}/config/agents.prod.yaml" && [ "${PRODUCTION_AGENT_TARGETS_REVIEWED:-false}" != "true" ]; then
    echo "ERROR: config/agents.prod.yaml still contains known development agent targets." >&2
    echo "Replace them with reviewed production targets, or set PRODUCTION_AGENT_TARGETS_REVIEWED=true only after confirming they are intentional." >&2
    exit 2
  fi
  if [ "${ALERT_NOTIFICATION_CHANNEL_COUNT}" -lt 1 ]; then
    echo "ERROR: Production deployments require ALERT_NOTIFICATION_CHANNELS_JSON with at least one notification channel." >&2
    exit 2
  fi
  WEBHOOK_SECRET_DEFAULT="$(sed -n '/variable "billing_api_stripe_webhook_signing_secret_id"/,/^}/p' "${ROOT_DIR}/infra/terraform/variables.tf" | sed -n 's/.*default[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ -z "${STRIPE_WEBHOOK_SIGNING_SECRET_ID:-${WEBHOOK_SECRET_DEFAULT}}" ]; then
    echo "ERROR: Production requires the live Stripe webhook signing secret ID." >&2
    exit 2
  fi
fi

# A copied template must not silently try to create or import the template's
# original v3 resources. New stacks should replace these defaults in
# infra/terraform/variables.tf before their first deployment.
if [ "${ALLOW_LEGACY_RESOURCE_NAMES:-false}" != "true" ]; then
  for LEGACY_NAME in \
    "ceoagent-gateway-v3" \
    "ceoagent-persistence-worker-v3" \
    "ceoagent-billing-api-v3" \
    "ceoagent-gateway-sa-v3" \
    "ceoagent-worker-sa-v3" \
    "ceoagent-billing-api-sa-v3" \
    "ceoagent-eventarc-sa-v3" \
    "ceoagent-reconciler-sa-v3" \
    "agent-turn-events-v3"; do
    if grep -Fq "default     = \"${LEGACY_NAME}\"" "${ROOT_DIR}/infra/terraform/variables.tf"; then
      echo "ERROR: infra/terraform/variables.tf still contains inherited resource name ${LEGACY_NAME}." >&2
      echo "Set unique service, service-account, and Pub/Sub names for this stack before deploying." >&2
      echo "ALLOW_LEGACY_RESOURCE_NAMES=true is only for a reviewed update of the original legacy stack." >&2
      exit 2
    fi
  done
fi

if [[ ! "${MIDDLEWARE_STACK_NAME}" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "ERROR: MIDDLEWARE_STACK_NAME must contain only lowercase letters, digits, and hyphens, and start with a letter." >&2
  exit 2
fi
if [[ ! "${MIDDLEWARE_IMAGE_PREFIX}" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "ERROR: MIDDLEWARE_IMAGE_PREFIX must contain only lowercase letters, digits, and hyphens, and start with a letter." >&2
  exit 2
fi
if [[ ! "${FIRESTORE_NAMESPACE}" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "ERROR: FIRESTORE_NAMESPACE must contain only lowercase letters, digits, and underscores, and start with a letter." >&2
  exit 2
fi

validate_firestore_collection() {
  local variable_name="$1"
  local collection_name="${!variable_name}"
  if [[ ! "${collection_name}" =~ ^[A-Za-z][A-Za-z0-9_-]{0,1499}$ ]]; then
    echo "ERROR: ${variable_name} must be a valid simple Firestore collection ID (1-1500 ASCII letters, digits, underscores, or hyphens; first character must be a letter)." >&2
    exit 2
  fi
}

for firestore_collection_variable in \
  FIRESTORE_THREADS_COLLECTION \
  FIRESTORE_MESSAGES_SUBCOLLECTION \
  FIRESTORE_IDEMPOTENCY_COLLECTION \
  FIRESTORE_BILLING_LEDGER_COLLECTION \
  FIRESTORE_CUSTOMER_WALLETS_COLLECTION \
  FIRESTORE_BILLING_RESERVATIONS_COLLECTION \
  FIRESTORE_WALLET_TRANSACTIONS_COLLECTION \
  FIRESTORE_CUSTOMER_BILLING_PERIODS_COLLECTION \
  FIRESTORE_CUSTOMER_BILLING_ACCOUNTS_COLLECTION \
  FIRESTORE_STRIPE_WEBHOOK_EVENTS_COLLECTION \
  FIRESTORE_SUBSCRIPTION_CANCELLATION_REQUESTS_COLLECTION; do
  validate_firestore_collection "${firestore_collection_variable}"
done

# Resolve only this stack's images. Never fall back to another stack's image,
# because a successful deploy with the wrong image is worse than a fast failure.
if [ -n "${TAG:-}" ] && [ "${TAG}" != "latest" ]; then
  GATEWAY_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${MIDDLEWARE_IMAGE_PREFIX}-gateway:${TAG}"
  WORKER_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${MIDDLEWARE_IMAGE_PREFIX}-persistence-worker:${TAG}"
  BILLING_API_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${MIDDLEWARE_IMAGE_PREFIX}-billing-api:${TAG}"
else
  echo "--> Resolving this stack's :latest image digests from Artifact Registry..."
  GATEWAY_NAME="${MIDDLEWARE_IMAGE_PREFIX}-gateway"
  WORKER_NAME="${MIDDLEWARE_IMAGE_PREFIX}-persistence-worker"
  BILLING_API_NAME="${MIDDLEWARE_IMAGE_PREFIX}-billing-api"

  GATEWAY_DIGEST="$(gcloud artifacts docker images describe "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${GATEWAY_NAME}:latest" --format='value(image_summary.digest)' 2>/dev/null || true)"
  WORKER_DIGEST="$(gcloud artifacts docker images describe "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${WORKER_NAME}:latest" --format='value(image_summary.digest)' 2>/dev/null || true)"
  BILLING_API_DIGEST="$(gcloud artifacts docker images describe "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${BILLING_API_NAME}:latest" --format='value(image_summary.digest)' 2>/dev/null || true)"

  if [ -z "${GATEWAY_DIGEST}" ] || [ -z "${WORKER_DIGEST}" ] || [ -z "${BILLING_API_DIGEST}" ]; then
    echo "ERROR: One or more ${MIDDLEWARE_IMAGE_PREFIX} images are missing. Run cloudshell_build_middleware.sh successfully first, or pass TAG=<git-sha>." >&2
    exit 1
  fi

  GATEWAY_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${GATEWAY_NAME}@${GATEWAY_DIGEST}"
  WORKER_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${WORKER_NAME}@${WORKER_DIGEST}"
  BILLING_API_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${BILLING_API_NAME}@${BILLING_API_DIGEST}"
fi

# A unique remote-state namespace prevents a copied template from claiming an
# existing middleware's resources. Existing legacy stacks must pass their old
# TF_STATE_PREFIX explicitly until they are deliberately migrated.
TF_STATE_PREFIX="${TF_STATE_PREFIX:-stacks/${MIDDLEWARE_STACK_NAME}/middleware}"

echo "================================================================="
echo " Deploying Middleware Infrastructure (Terraform)"
echo " Project ID          : ${PROJECT_ID}"
echo " Region              : ${REGION}"
echo " Stack Name          : ${MIDDLEWARE_STACK_NAME}"
echo " Image Prefix        : ${MIDDLEWARE_IMAGE_PREFIX}"
echo " Firestore Namespace : ${FIRESTORE_NAMESPACE}"
echo " Firestore Collections:"
echo "   threads                  : ${FIRESTORE_THREADS_COLLECTION}"
echo "   messages subcollection   : ${FIRESTORE_MESSAGES_SUBCOLLECTION}"
echo "   idempotency              : ${FIRESTORE_IDEMPOTENCY_COLLECTION}"
echo "   billing ledger           : ${FIRESTORE_BILLING_LEDGER_COLLECTION}"
echo "   customer wallets         : ${FIRESTORE_CUSTOMER_WALLETS_COLLECTION}"
echo "   billing reservations     : ${FIRESTORE_BILLING_RESERVATIONS_COLLECTION}"
echo "   wallet transactions      : ${FIRESTORE_WALLET_TRANSACTIONS_COLLECTION}"
echo "   customer billing periods : ${FIRESTORE_CUSTOMER_BILLING_PERIODS_COLLECTION}"
echo "   billing accounts         : ${FIRESTORE_CUSTOMER_BILLING_ACCOUNTS_COLLECTION}"
echo "   Stripe webhook events    : ${FIRESTORE_STRIPE_WEBHOOK_EVENTS_COLLECTION}"
echo "   cancellation requests    : ${FIRESTORE_SUBSCRIPTION_CANCELLATION_REQUESTS_COLLECTION}"
echo " State Prefix        : ${TF_STATE_PREFIX}"
echo " Gateway Image       : ${GATEWAY_IMAGE}"
echo " Worker Image        : ${WORKER_IMAGE}"
echo " Billing API Image   : ${BILLING_API_IMAGE}"
echo "================================================================="

cd "${ROOT_DIR}/infra/terraform"
rm -f terraform.auto.tfvars.json middleware.tfplan

cat > backend.hcl <<EOF
bucket = "${PROJECT_ID}-tfstate"
prefix = "${TF_STATE_PREFIX}"
EOF

terraform init -backend-config=backend.hcl -reconfigure

EXTRA_TFVARS=",\"billing_api_catalog_path\": \"${BILLING_CATALOG_PATH}\""
if [ -n "${STRIPE_WEBHOOK_SIGNING_SECRET_ID:-}" ]; then
  EXTRA_TFVARS="${EXTRA_TFVARS},\"billing_api_stripe_webhook_signing_secret_id\": \"${STRIPE_WEBHOOK_SIGNING_SECRET_ID}\",\"billing_api_stripe_webhook_signing_secret_version\": \"${STRIPE_WEBHOOK_SIGNING_SECRET_VERSION:-1}\""
fi

cat > terraform.auto.tfvars.json <<EOF
{
  "project_id": "${PROJECT_ID}",
  "region": "${REGION}",
  "gateway_image": "${GATEWAY_IMAGE}",
  "worker_image": "${WORKER_IMAGE}",
  "billing_api_image": "${BILLING_API_IMAGE}",
  "deployment_environment": "${DEPLOYMENT_ENV}",
  "alert_notification_channels": ${ALERT_NOTIFICATION_CHANNELS_JSON},
  "allowed_origins": ["https://ceoappdev.flutterflow.app"],
  "billing_api_allowed_origins": ["https://ceoappdev.flutterflow.app"],
  "billing_api_stripe_secret_key_secret_version": "1",
  "billing_api_checkout_success_url": "https://ceoappdev.flutterflow.app/billing-complete?session_id={CHECKOUT_SESSION_ID}",
  "billing_api_checkout_cancel_url": "https://ceoappdev.flutterflow.app/billing-cancelled",
  "billing_enforcement_enabled": true,
  "billing_reconciliation_enabled": true,
  "firestore_threads_collection": "${FIRESTORE_THREADS_COLLECTION}",
  "firestore_messages_subcollection": "${FIRESTORE_MESSAGES_SUBCOLLECTION}",
  "firestore_idempotency_collection": "${FIRESTORE_IDEMPOTENCY_COLLECTION}",
  "firestore_billing_ledger_collection": "${FIRESTORE_BILLING_LEDGER_COLLECTION}",
  "firestore_customer_wallets_collection": "${FIRESTORE_CUSTOMER_WALLETS_COLLECTION}",
  "firestore_billing_reservations_collection": "${FIRESTORE_BILLING_RESERVATIONS_COLLECTION}",
  "firestore_wallet_transactions_collection": "${FIRESTORE_WALLET_TRANSACTIONS_COLLECTION}",
  "firestore_customer_billing_periods_collection": "${FIRESTORE_CUSTOMER_BILLING_PERIODS_COLLECTION}",
  "firestore_customer_billing_accounts_collection": "${FIRESTORE_CUSTOMER_BILLING_ACCOUNTS_COLLECTION}",
  "firestore_stripe_webhook_events_collection": "${FIRESTORE_STRIPE_WEBHOOK_EVENTS_COLLECTION}",
  "firestore_subscription_cancellation_requests_collection": "${FIRESTORE_SUBSCRIPTION_CANCELLATION_REQUESTS_COLLECTION}"${EXTRA_TFVARS}
}
EOF

# Importing another stack's resources makes a renamed configuration look like
# a deletion. Recovery imports are therefore explicitly opt-in.
if [ "${IMPORT_EXISTING_RESOURCES:-false}" = "true" ]; then
  bash "${ROOT_DIR}/scripts/import_existing_resources.sh"
fi

PLAN_FILE="middleware.tfplan"
set +e
terraform plan -detailed-exitcode -out="${PLAN_FILE}"
PLAN_EXIT=$?
set -e

if [ "${PLAN_EXIT}" -eq 0 ]; then
  echo "No infrastructure changes to apply."
  terraform output
  exit 0
elif [ "${PLAN_EXIT}" -ne 2 ]; then
  exit "${PLAN_EXIT}"
fi

DESTRUCTIVE_ADDRESSES="$(terraform show -json "${PLAN_FILE}" | python3 -c '
import json
import sys

for resource in json.load(sys.stdin).get("resource_changes", []):
    if "delete" in resource.get("change", {}).get("actions", []):
        print(resource["address"])
')"

if [ -n "${DESTRUCTIVE_ADDRESSES}" ] && [ "${ALLOW_TERRAFORM_DELETES:-false}" != "true" ]; then
  echo "ERROR: Terraform plans to delete or replace the following resources:" >&2
  echo "${DESTRUCTIVE_ADDRESSES}" >&2
  echo "Refusing to apply. Verify TF_STATE_PREFIX and resource names. Set ALLOW_TERRAFORM_DELETES=true only for an intentional, reviewed deletion." >&2
  exit 1
fi

if [ "${TERRAFORM_AUTO_APPROVE:-false}" = "true" ]; then
  terraform apply -auto-approve "${PLAN_FILE}"
elif [ -t 0 ]; then
  read -r -p "Apply the reviewed Terraform plan above? Type 'yes' to continue: " APPLY_CONFIRMATION
  if [ "${APPLY_CONFIRMATION}" != "yes" ]; then
    echo "Terraform apply cancelled; the saved plan remains at ${PLAN_FILE}."
    exit 1
  fi
  terraform apply "${PLAN_FILE}"
else
  echo "ERROR: Refusing to apply a Terraform plan non-interactively without TERRAFORM_AUTO_APPROVE=true." >&2
  echo "Review the plan and rerun interactively, or set the explicit opt-in for an approved automation." >&2
  exit 1
fi
rm -f "${PLAN_FILE}"

echo "================================================================="
echo " Middleware Deployed Successfully!"
echo "================================================================="
terraform output
