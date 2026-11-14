#!/usr/bin/env bash
set -euo pipefail

# Bootstraps an AWS account with the terraform-bootstrap module.
#
# Solves the chicken-and-egg problem: the bootstrap stack needs somewhere to
# keep its own state before the module has created anything. This script
# creates a small S3 bucket for that, initialises the backend against it,
# then runs Terraform.
#
# Usage:
#   bootstrap.sh <env> [plan|apply|destroy] [options]
#
# Options:
#   -d, --dir DIR         Terraform root that calls the module (default: current dir)
#   -c, --common FILE     Shared tfvars JSON   (default: DIR/envs/common.auto.tfvars.json)
#   -e, --env-file FILE   Per-env tfvars JSON  (default: DIR/envs/<env>.tfvars.json)
#   -f, --force           On destroy, also delete the bootstrap state bucket without prompting
#   -h, --help            Show this help
#
# The tfvars files (env file wins on conflicts) must provide:
#   project, region, environment
# and may provide:
#   aws_account_id   refuse to run if the current credentials are for another account
#   extra_tags       map of tags applied to the bootstrap state bucket
#
# Requires: terraform >= 1.10 (S3 native locking), awscli v2, jq

usage() { sed -n '4,25p' "$0" | sed 's/^# \{0,1\}//'; }

ENV=""
ACTION="apply"
TF_ROOT="$PWD"
COMMON_FILE=""
ENV_FILE=""
FORCE_DELETE="false"

positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir)      TF_ROOT="${2:?--dir needs a value}"; shift 2 ;;
    -c|--common)   COMMON_FILE="${2:?--common needs a value}"; shift 2 ;;
    -e|--env-file) ENV_FILE="${2:?--env-file needs a value}"; shift 2 ;;
    -f|--force)    FORCE_DELETE="true"; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)             positional+=("$1"); shift ;;
  esac
done

ENV="${positional[0]:-}"
ACTION="${positional[1]:-apply}"
[[ -n "$ENV" ]] || { usage >&2; exit 1; }
case "$ACTION" in plan|apply|destroy) ;; *) echo "Unknown action: $ACTION (expected plan|apply|destroy)" >&2; exit 1 ;; esac

TF_ROOT="$(cd "$TF_ROOT" && pwd)"
COMMON_FILE="${COMMON_FILE:-$TF_ROOT/envs/common.auto.tfvars.json}"
ENV_FILE="${ENV_FILE:-$TF_ROOT/envs/${ENV}.tfvars.json}"

for bin in jq aws terraform; do
  command -v "$bin" >/dev/null || { echo "Missing dependency: $bin" >&2; exit 1; }
done

compgen -G "$TF_ROOT/*.tf" >/dev/null || { echo "No .tf files in Terraform root: $TF_ROOT" >&2; exit 1; }
[[ -f "$COMMON_FILE" ]] || { echo "Missing common tfvars: $COMMON_FILE" >&2; exit 1; }
[[ -f "$ENV_FILE"    ]] || { echo "Missing env tfvars: $ENV_FILE" >&2; exit 1; }

COMMON_FILE="$(cd "$(dirname "$COMMON_FILE")" && pwd)/$(basename "$COMMON_FILE")"
ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"

# Merged view of both files (env overrides common).
VARS_JSON="$(jq -s '.[0] * .[1]' "$COMMON_FILE" "$ENV_FILE")"
get() { jq -r --arg k "$1" '.[$k] // empty' <<<"$VARS_JSON"; }

PROJECT="$(get project)"
REGION="$(get region)"
ENVIRONMENT="$(get environment)"
EXPECTED_ID="$(get aws_account_id)"

for v in PROJECT REGION ENVIRONMENT; do
  [[ -n "${!v}" ]] || { echo "❌ '$(tr '[:upper:]' '[:lower:]' <<<"$v")' must be set in $COMMON_FILE or $ENV_FILE" >&2; exit 1; }
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
[[ -n "$ACCOUNT_ID" && "$ACCOUNT_ID" != "None" ]] || { echo "❌ No AWS credentials. Run 'aws sso login' or set AWS_PROFILE." >&2; exit 1; }
if [[ -n "$EXPECTED_ID" && "$EXPECTED_ID" != "$ACCOUNT_ID" ]]; then
  echo "❌ Expected AWS account $EXPECTED_ID for env '$ENV', but credentials are for $ACCOUNT_ID" >&2
  exit 1
fi

BUCKET="${ACCOUNT_ID}-${REGION}-${PROJECT}-${ENVIRONMENT}-bootstrap"
KEY="terraform.tfstate"

TAGS_JSON="$(jq -c \
  --arg project "$PROJECT" --arg environment "$ENVIRONMENT" --arg region "$REGION" \
  '(.extra_tags // {}) + {project:$project, environment:$environment, region:$region, module:"terraform-bootstrap"}' \
  <<<"$VARS_JSON")"
S3_TAGSET_JSON="$(jq -c 'to_entries | {TagSet: map({Key:.key, Value:(.value|tostring)})}' <<<"$TAGS_JSON")"

cat <<INFO
Env:        $ENV
Action:     $ACTION
TF root:    $TF_ROOT
Account:    $ACCOUNT_ID
Region:     $REGION
Project:    $PROJECT
State:      s3://$BUCKET/$KEY (S3 native locking)
Tags:       $TAGS_JSON
INFO

# Per-env plugin/module cache so switching envs never reuses another env's backend.
export TF_DATA_DIR="${TF_ROOT}/.terraform-${ENV}"
export AWS_REGION="$REGION"

empty_versioned_bucket() {
  local bucket="$1" resp to_delete count truncated key_marker="" ver_marker=""
  echo "Emptying versioned bucket: $bucket"
  while :; do
    if [[ -n "$key_marker" ]]; then
      resp="$(aws s3api list-object-versions --bucket "$bucket" --key-marker "$key_marker" --version-id-marker "$ver_marker" --output json)"
    else
      resp="$(aws s3api list-object-versions --bucket "$bucket" --output json)"
    fi
    to_delete="$(jq -c '{Objects: [(.Versions // [])[], (.DeleteMarkers // [])[] | {Key, VersionId}], Quiet: true}' <<<"$resp")"
    count="$(jq '.Objects | length' <<<"$to_delete")"
    if (( count > 0 )); then
      echo "  deleting $count object versions/markers"
      aws s3api delete-objects --bucket "$bucket" --delete "$to_delete" >/dev/null
    fi
    truncated="$(jq -r '.IsTruncated // false' <<<"$resp")"
    [[ "$truncated" == "true" ]] || break
    key_marker="$(jq -r '.NextKeyMarker // empty' <<<"$resp")"
    ver_marker="$(jq -r '.NextVersionIdMarker // empty' <<<"$resp")"
  done
}

# ---------- Ensure the bootstrap state bucket exists ----------
if [[ "$ACTION" != "destroy" ]]; then
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "State bucket exists: $BUCKET"
  else
    echo "Creating state bucket: $BUCKET"
    if [[ "$REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$BUCKET" >/dev/null
    else
      aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
    fi
    aws s3api wait bucket-exists --bucket "$BUCKET"
    aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption --bucket "$BUCKET" \
      --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    aws s3api put-public-access-block --bucket "$BUCKET" \
      --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
  fi
  aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "$S3_TAGSET_JSON"
fi

# ---------- Init ----------
terraform -chdir="$TF_ROOT" init -reconfigure -input=false \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="key=${KEY}" \
  -backend-config="region=${REGION}" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"

VAR_ARGS=(-var-file="$COMMON_FILE" -var-file="$ENV_FILE")

# ---------- Run ----------
case "$ACTION" in
  plan)
    terraform -chdir="$TF_ROOT" plan -input=false "${VAR_ARGS[@]}"
    ;;
  apply)
    PLAN_FILE="${TF_DATA_DIR}/bootstrap.tfplan"
    terraform -chdir="$TF_ROOT" plan -input=false -out="$PLAN_FILE" "${VAR_ARGS[@]}"
    if [[ -t 0 ]]; then
      read -r -p "Apply this plan? (y/N): " ANS
      [[ "$ANS" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    fi
    terraform -chdir="$TF_ROOT" apply -input=false "$PLAN_FILE"
    rm -f "$PLAN_FILE"
    ;;
  destroy)
    terraform -chdir="$TF_ROOT" destroy "${VAR_ARGS[@]}"
    echo
    if [[ "$FORCE_DELETE" == "true" ]]; then
      ANS="y"
    else
      read -r -p "Also delete the bootstrap state bucket ${BUCKET}? (y/N): " ANS
    fi
    if [[ "$ANS" =~ ^[Yy]$ ]]; then
      if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
        empty_versioned_bucket "$BUCKET"
        aws s3api delete-bucket --bucket "$BUCKET"
        echo "Deleted $BUCKET"
      else
        echo "Bucket $BUCKET does not exist."
      fi
    else
      echo "Left state bucket intact: $BUCKET"
    fi
    ;;
esac

echo "✅ Done: $ENV $ACTION"
