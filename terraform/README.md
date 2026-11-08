# Terraform — AWS layer

Flat root module for the existing homelab. No modules, no environment tree yet (ADR-023).

## Auth

Terraform uses the same credential chain as the AWS CLI. No keys in code.

```bash
export AWS_PROFILE=homelab
export AWS_REGION=eu-north-1
aws sts get-caller-identity
```

## Commands

```bash
terraform init
terraform fmt -recursive .
terraform validate
terraform plan
terraform apply
terraform state list
terraform output
```

## What it manages

| Resource | Address |
|---|---|
| EC2 instance | `aws_instance.homelab` |
| 10 GiB data volume | `aws_ebs_volume.data` |
| Volume attachment | `aws_volume_attachment.data` (at `/dev/sdd`; the AMI reserves `/dev/sdb` and `/dev/sdc` for ephemeral devices) |
| Node security group | `aws_security_group.node` |

The default VPC, subnets, IGW and key pair are **data sources**: the VPC is shared with another
project, so Terraform must never own it.

## Node bootstrap

The instance uses `user_data = file("../bootstrap/cloud-init.yaml")`. On a new instance,
cloud-init:

- waits for the 10 GiB volume, labels it `cnh-data`, mounts it, and adds it to `/etc/fstab`;
- installs k3s `v1.37.2+k3s1`;
- installs Helm `v3.22.1` and helmfile `v1.8.3`.

It contains **no secrets**. `user_data` is under `ignore_changes`, so editing the file does not
affect the running node; it is used on the next instance creation. To re-bootstrap an existing
instance, replace it deliberately:

```bash
terraform apply -replace=aws_instance.homelab
```

The data volume and security group are not replaced by that command.

## After apply

Run the deploy script from the repo root to install the apps and observability:

```bash
./scripts/deploy.sh
```

It copies `k8s/` and `helmfile.yaml` to the node, creates the Grafana secret, and runs
`helmfile sync`.

## State

Local backend: `terraform.tfstate` (gitignored). Losing it means re-importing.

Next: create an S3 bucket (versioning, SSE, public access blocked), switch `backend.tf` to the
S3 block, then:

```bash
terraform init -migrate-state
```

## Import

Resources were adopted once with `import {}` blocks. Those blocks were removed after the
import succeeded — keeping them causes `Cannot import non-existent remote object` when a
resource is later recreated.

To add another existing resource, add a temporary `import` block and use:

```bash
terraform plan -generate-config-out=generated.tf
```

## Safety

- Do not run `terraform destroy`: it removes the instance, the **retained** data volume, and
  the SG.
- Add `prevent_destroy` to the data volume before any destructive work.
- Drift to fix (T20): SSH `0.0.0.0/0`, unused port 30076, unencrypted volumes, missing IAM/S3/
  alarms/snapshots.
