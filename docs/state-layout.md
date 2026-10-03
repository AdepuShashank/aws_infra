# Remote state layout

## Bootstrap is the only local-state layer

`infra/bootstrap` keeps its state **on the local disk** on purpose. It creates
the S3 bucket that every other layer uses as a backend, so it cannot use that
bucket to store its own state.

```
infra/bootstrap/terraform.tfstate   <- local, never committed (gitignored)
infra/envs/<env>/<layer>/            <- remote state in S3
```

Once `infra/bootstrap` has been applied, copy its bucket name, region and KMS
key ARN into each layer's `backend "s3"` block and run `terraform init -migrate-state`.

## Bucket and key layout

Bootstrap is applied **once per environment**, which gives each environment its
own bucket, key and IAM roles:

| Env  | Bucket            | KMS alias                 | State operator role   |
| ---- | ----------------- | ------------------------- | --------------------- |
| prod | `dpx-tfstate-prod` | `alias/dpx-prod-tfstate`  | `dpx-prod-state-admin` |
| qa   | `dpx-tfstate-qa`   | `alias/dpx-qa-tfstate`    | `dpx-qa-state-admin`   |

Bucket names are globally unique in S3. If `dpx-tfstate-prod` is already taken,
pass `state_bucket_name` explicitly.

## Object keys

```
<env>/<layer>/terraform.tfstate
<env>/<layer>/terraform.tfstate.backup   (server-side, versioning enabled)
<env>/<layer>/<name>.tflock              (S3 native lockfile)
```

`<layer>` is the numeric layer directory name, for example `20-security`.

## Locking

Locking uses S3 native lock files (`use_lockfile = true`). There is **no DynamoDB
table** - the `tflock` object is the lock, which removes a whole service and its
IAM/DynamoDB permissions from the critical path.

```
terraform {
  backend "s3" {
    bucket       = "dpx-tfstate-prod"
    key          = "prod/20-security/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    kms_key_id   = "alias/dpx-prod-tfstate"
    use_lockfile = true
  }
}
```

`kms_key_id` uses the alias, not the key id, so the key can be rotated without
editing every backend block.

## Deletion behaviour

| Env  | `force_destroy` | Rationale                                            |
| ---- | ---------------- | ---------------------------------------------------- |
| prod | `false`          | State survives an accidental `terraform destroy`.    |
| qa   | `true`           | qa is disposable, so a full teardown should succeed. |

## Ordering

1. `infra/bootstrap` (prod) - local state.
2. `infra/bootstrap` (qa) - local state.
3. Enable the S3 backend in every `infra/envs/**` directory.
4. `terraform init -migrate-state` per layer, then verify the plan is empty
   before touching any real infrastructure.