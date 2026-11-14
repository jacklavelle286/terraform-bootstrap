# terraform-bootstrap

A reusable Terraform module that bootstraps an AWS account so a repo's GitHub Actions can deploy to it, with no long-lived AWS keys.

For one project and environment, it creates:

| Resource | Purpose |
|---|---|
| **GitHub OIDC identity provider** | Lets GitHub Actions exchange its OIDC token for AWS credentials. Only one is allowed per account (see [Several projects in one account](#several-projects-in-one-account)). |
| **IAM role for CI** | Assumed by the workflows you list in `trusted_subs`. You choose its permissions. |
| **S3 state bucket** | Remote state for the project's *main* Terraform stack. It has versioning, encryption, a public access block, a TLS-only policy and object-ownership enforcement. |
| **ECR repositories** (optional) | One per entry in `ecr_repos`, each with a lifecycle policy (untagged images expire after 1 day; the last N images are kept). |
| DynamoDB lock table (optional, off by default) | Only for Terraform < 1.10. Newer versions lock state in S3 itself. |

```
terraform-bootstrap/
├── modules/bootstrap/        ← the module (this is what other repos reference)
│   └── tests/                ← `terraform test` with a mocked provider
├── examples/github-oidc/     ← a complete caller to copy into your repo
└── scripts/bootstrap.sh      ← first-run helper (creates the bootstrap's own state bucket)
```

## Requirements

- Terraform **>= 1.10** for the example and script (S3 native locking). The module on its own needs >= 1.9.
- AWS provider **6.x**
- AWS CLI v2 and `jq` (only for the script)
- Admin-level credentials for the target account the first time you run it, e.g. `aws sso login --profile my-staging`

---

## Using it from another repo

### 1. Add a bootstrap folder to the consuming repo

Copy [examples/github-oidc](examples/github-oidc) into the repo, e.g. as `infrastructure/bootstrap/`:

```
my-app/
└── infrastructure/
    └── bootstrap/
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── envs/
            ├── common.auto.tfvars.json
            ├── staging.tfvars.json
            └── prod.tfvars.json
```

In `main.tf`, point `source` at this repo and **pin it to a tag**:

```hcl
module "bootstrap" {
  source = "git::ssh://git@github.com/jacklavelle286/terraform-bootstrap.git//modules/bootstrap?ref=v1.0.0"

  project     = var.project
  environment = var.environment
  tags        = var.extra_tags

  trusted_subs     = var.trusted_subs
  role_policy_arns = var.role_policy_arns

  ecr_repos = var.ecr_repos
}
```

- `//modules/bootstrap` is the subfolder inside this repo that holds the module.
- `?ref=v1.0.0` pins the version, so changes here only reach a consuming repo when it bumps the tag and runs `terraform init -upgrade`.
- Use the `git::https://github.com/...` form instead of `ssh://` if your CI clones over HTTPS.

The region comes from the `provider "aws"` block in the consuming repo. The module has no provider block of its own.

### 2. Fill in the tfvars

`envs/common.auto.tfvars.json` holds settings shared by all environments:

```json
{
  "project": "my-app",
  "region": "eu-west-2",
  "trusted_subs": ["repo:my-org/my-app:*"],
  "ecr_repos": [{ "repo_name": "backend" }],
  "extra_tags": { "owner": "platform" }
}
```

`envs/staging.tfvars.json` holds per-environment settings, one file per AWS account:

```json
{
  "environment": "staging",
  "aws_account_id": "111111111111",
  "role_policy_arns": ["arn:aws:iam::aws:policy/AdministratorAccess"]
}
```

`aws_account_id` is a safety check: the script refuses to run if your current credentials are for a different account.

The role gets **no permissions by default**. Grant them with `role_policy_arns` (managed policies) and/or `role_inline_policy_json`. `AdministratorAccess` is the quickest option, but a tighter policy is better for production.

### 3. Run the bootstrap

The bootstrap stack needs its own state somewhere before anything exists. `scripts/bootstrap.sh` handles that: it creates a small `<account>-<region>-<project>-<env>-bootstrap` bucket, runs `terraform init` against it, then plans and applies.

**The script does not need to live in the consuming repo.** Terraform only downloads the module's `.tf` files, so the script never comes along through `source =` anyway. Pick one of these:

**a) Run it from a clone of this repo (recommended).** Nothing gets copied, and every repo uses the same script:

```bash
git clone git@github.com:jacklavelle286/terraform-bootstrap.git ~/src/terraform-bootstrap
cd ~/src/terraform-bootstrap && git checkout v1.0.0

~/src/terraform-bootstrap/scripts/bootstrap.sh staging plan  --dir ~/src/my-app/infrastructure/bootstrap
~/src/terraform-bootstrap/scripts/bootstrap.sh staging apply --dir ~/src/my-app/infrastructure/bootstrap
```

**b) Copy it into the consuming repo** (e.g. `infrastructure/bootstrap/bootstrap.sh`) if you want the repo to be self-contained. Then run it from that folder:

```bash
cd infrastructure/bootstrap
./bootstrap.sh staging apply
```

The trade-off is that fixes to the script here won't reach that copy automatically.

Script options:

```
bootstrap.sh <env> [plan|apply|destroy] [options]
  -d, --dir DIR         Terraform root that calls the module (default: current dir)
  -c, --common FILE     Shared tfvars   (default: DIR/envs/common.auto.tfvars.json)
  -e, --env-file FILE   Per-env tfvars  (default: DIR/envs/<env>.tfvars.json)
  -f, --force           On destroy, also delete the bootstrap state bucket without prompting
```

When run in a terminal, `apply` asks for confirmation before applying. It runs unattended when there's no TTY (e.g. in CI).

You **don't have to use the script**. If you already have somewhere to keep the bootstrap state, run plain Terraform:

```bash
terraform init -backend-config="bucket=..." -backend-config="key=bootstrap/terraform.tfstate" \
               -backend-config="region=eu-west-2" -backend-config="use_lockfile=true"
terraform apply -var-file=envs/common.auto.tfvars.json -var-file=envs/staging.tfvars.json
```

### 4. Use the outputs

```bash
terraform -chdir=infrastructure/bootstrap output
# ci_role_arn         = "arn:aws:iam::111111111111:role/my-app-staging-github-oidc"
# state_bucket_name   = "111111111111-eu-west-2-my-app-staging"
# ecr_repository_urls = { backend = "111111111111.dkr.ecr.eu-west-2.amazonaws.com/my-app-staging-eu-west-2-backend" }
```

> If you used the script, run `export TF_DATA_DIR=infrastructure/bootstrap/.terraform-staging` first, because the script keeps a separate `.terraform` folder per environment.

**In GitHub Actions:**

```yaml
permissions:
  id-token: write   # required for OIDC
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::111111111111:role/my-app-staging-github-oidc   # ci_role_arn
          aws-region: eu-west-2
      - run: aws sts get-caller-identity
```

**As the backend for the main stack:**

```hcl
terraform {
  backend "s3" {
    bucket       = "111111111111-eu-west-2-my-app-staging"   # state_bucket_name
    key          = "main/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}
```

---

## Common setups

### Restricting which workflows can assume the role

`trusted_subs` is matched with `StringLike` against the token's `sub` claim:

```json
"trusted_subs": [
  "repo:my-org/my-app:ref:refs/heads/main",
  "repo:my-org/my-app:environment:prod"
]
```

`repo:my-org/my-app:*` allows any branch, tag, PR or environment in that repo. That's fine for staging, but too broad for prod.

### Several projects in one account

AWS allows only **one** GitHub OIDC provider per account. The first project to bootstrap the account creates it. Every other project in that account should reuse it:

```hcl
module "bootstrap" {
  # ...
  create_oidc_provider = false
  oidc_provider_arn    = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
}
```

Each project gets its own role, bucket and ECR repos, because they're all named after `project` and `environment`.

### Tearing down

```bash
scripts/bootstrap.sh staging destroy --dir path/to/bootstrap
```

The main-stack state bucket has `state_bucket_force_destroy = false` by default, so destroy **fails if the bucket still holds state**. That's deliberate: destroy the main stack first, or set the variable to `true` for throwaway environments. ECR works the same way with `ecr_force_delete`.

---

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `project` | string | — | Project name. Used in names and tags. |
| `environment` | string | — | Environment name. Used in names and tags. |
| `trusted_subs` | list(string) | — | OIDC `sub` patterns allowed to assume the role. |
| `tags` | map(string) | `{}` | Extra tags for every resource. |
| `create_oidc_provider` | bool | `true` | Create the account-wide OIDC provider. |
| `oidc_provider_arn` | string | `null` | Existing provider ARN. Required if `create_oidc_provider = false`. |
| `oidc_url` | string | GitHub | OIDC issuer URL. |
| `oidc_client_id_list` | list(string) | `["sts.amazonaws.com"]` | Accepted audiences. |
| `oidc_thumbprint_list` | list(string) | GitHub thumbprint | Provider thumbprints. |
| `role_name` | string | `<project>-<environment>-github-oidc` | CI role name. |
| `role_policy_arns` | list(string) | `[]` | Managed policies to attach to the role. |
| `role_inline_policy_json` | string | `null` | Inline policy JSON for the role. |
| `role_max_session_duration` | number | `3600` | Maximum session length in seconds. |
| `create_state_bucket` | bool | `true` | Create the main-stack state bucket. |
| `state_bucket_name` | string | `<account>-<region>-<project>-<environment>` | Bucket name override. |
| `state_bucket_force_destroy` | bool | `false` | Allow deleting a non-empty bucket. |
| `create_lock_table` | bool | `false` | Create a DynamoDB lock table (Terraform < 1.10 only). |
| `lock_table_name` | string | same as bucket | Lock table name override. |
| `ecr_repos` | list(object({repo_name})) | `[]` | ECR repos, named `<project>-<environment>-<region>-<repo_name>`. |
| `ecr_image_tag_mutability` | string | `MUTABLE` | `MUTABLE` or `IMMUTABLE`. |
| `ecr_scan_on_push` | bool | `true` | Basic image scanning on push. |
| `ecr_force_delete` | bool | `false` | Allow deleting repos that still contain images. |
| `ecr_keep_image_count` | number | `5` | Most-recent images kept per repo. |

## Outputs

| Name | Description |
|---|---|
| `account_id`, `region` | Where the module was applied. |
| `oidc_provider_arn` | The OIDC provider ARN (created or passed in). |
| `ci_role_arn`, `ci_role_name` | The CI role. Use the ARN as `role-to-assume`. |
| `state_bucket_name`, `state_bucket_arn` | The main-stack state bucket (`null` if not created). |
| `lock_table_name` | The DynamoDB lock table (`null` if not created). |
| `ecr_repository_urls`, `ecr_repository_arns` | Maps of `repo_name` to URL or ARN. |

---

## Releasing a new version

```bash
cd modules/bootstrap && terraform init && terraform test   # mocked provider, no AWS creds needed
git tag v1.1.0 && git push origin v1.1.0
```

Use semver. Bump the **major** version for anything that renames or replaces resources, changes defaults in a way that alters existing infrastructure, or removes or renames a variable. Consumers upgrade by changing `?ref=` and running `terraform init -upgrade && terraform plan`.

---

## Migrating from the old in-repo module

If a repo (e.g. `jacks-productivity-tool`) uses the original `infrastructure/modules/bootstrap`, the module includes `moved` blocks, so switching `source` to this repo **won't recreate** the OIDC provider, role, bucket, lock table or ECR repos. To keep the existing names and behaviour, set:

```hcl
module "bootstrap" {
  source = "git::ssh://git@github.com/jacklavelle286/terraform-bootstrap.git//modules/bootstrap?ref=v1.0.0"

  project      = var.project
  environment  = var.environment
  trusted_subs = ["repo:jacklavelle286/jacks-productivity-tool*"]
  ecr_repos    = [{ repo_name = "backend" }]

  role_name         = "github-federation"   # old hardcoded name; changing it replaces the role
  create_lock_table = true                   # keep the existing DynamoDB table until the backend uses use_lockfile
  ecr_force_delete  = true                   # old behaviour
  state_bucket_force_destroy = true          # old behaviour (not recommended)

  # The old module attached a "<project>-ecr-policy" granting *:*. That policy
  # is removed; grant equivalent access explicitly:
  role_policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}
```

What to expect in the first `plan` after switching:

- `aws_iam_policy.ecr_perms` and its attachment are **destroyed**, and `AdministratorAccess` is attached instead.
- The state bucket **gains** versioning, encryption, a public access block, ownership controls and a TLS-only policy. These are new resources and don't replace the bucket.
- The DynamoDB table changes from provisioned to on-demand billing in place.
- ECR repos gain scan-on-push in place.
- The old module took a `region` variable, but this one reads the region from the provider. Remove `region = ...` from the module call and set it on `provider "aws"`.
- The bootstrap root config needs AWS provider 6.x. It's a separate stack from the main one, so the main stack's provider version is unaffected.

**Read the plan before applying.** If anything shows `must be replaced`, stop and check which input differs from the old setup.
