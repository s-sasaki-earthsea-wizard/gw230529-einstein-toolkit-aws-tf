# IAM policy for the Terraform operator

`terraform-operator.json` is the single policy the Terraform principal needs.
It replaces the AWS managed policies rather than supplementing them — attach
it alone.

Verify it before attaching, and again after:

```bash
make check-permissions-policy    # simulate the document, attached to nothing
make check-permissions PRINCIPAL=arn:aws:iam::<account-id>:user/<operator>
```

Both must end in `OK: all 109 actions permitted`.

## Scoping

Resources are fenced by the `gw230529-` name prefix wherever AWS supports
resource-level permissions:

| Service | Scope |
| --- | --- |
| S3 | `arn:aws:s3:::gw230529-*` and its objects |
| ECR | `repository/gw230529*` |
| IAM | `role/gw230529-*`, `instance-profile/gw230529-*` |
| SNS | `gw230529-*` topics |
| EventBridge | `rule/gw230529-*` |
| Budgets | `budget/gw230529-*` |
| SSM parameters | only `/aws/service/ami-amazon-latest/*`, the public AMI index |

Four things cannot be scoped, and are granted on `*` deliberately:

- **EC2.** Its ARNs carry no project name, so no prefix pattern can separate
  this project's VPC from any other. A pattern like
  `arn:aws:ec2:*:*:*/*` looks restrictive but matches every EC2 resource in
  the account — it is `*` written the long way.
- **Cost Explorer.** `ce:*` has no resource-level permissions at all.
- **Session Manager.** `ssm:StartSession` targets an instance ARN, which
  brings back the EC2 problem.
- **`ec2:GetSpotPlacementScores`, `servicequotas:*`, `ecr:GetAuthorizationToken`,
  `s3:ListAllMyBuckets`.** Account-wide queries with no resource to scope to.

## The EC2 guard

Because EC2 cannot be scoped by name, the policy carries an explicit `Deny`
on destructive EC2 actions whose target is not tagged `Project=gw230529`:

```json
"Condition": { "StringNotEquals": { "aws:ResourceTag/Project": "gw230529" } }
```

Provider `default_tags` stamps that tag on everything this project creates,
so Terraform can still delete its own resources. An untagged instance, or one
belonging to another project in the same account, returns `explicitDeny` — and
an explicit Deny cannot be overridden by any Allow.

Verified behaviour:

| Target | `ec2:TerminateInstances` |
| --- | --- |
| `Project=gw230529` | allowed |
| tag absent | explicitDeny |
| `Project=some-other-project` | explicitDeny |

The trade: a resource that somehow ends up untagged becomes undeletable
through this principal, and `terraform destroy` will stop on it. That is the
guard working, not a bug — retag the resource or delete it with another
principal.

## What this policy does not grant

No `iam:AttachUserPolicy`, no `iam:CreatePolicy`, no ability to touch roles
outside `gw230529-*`. The principal therefore cannot escalate itself to
administrator, which is the property the earlier `IAMFullAccess` arrangement
did not have.

## Attaching it

```bash
aws iam create-policy \
  --policy-name gw230529-terraform-operator \
  --policy-document file://policies/terraform-operator.json

aws iam attach-user-policy \
  --user-name <operator> \
  --policy-arn arn:aws:iam::<account-id>:policy/gw230529-terraform-operator

# Detach anything it replaces, including the broad managed policies.
aws iam list-attached-user-policies --user-name <operator>
```

Updating it later means creating a new policy *version*:

```bash
aws iam create-policy-version \
  --policy-arn arn:aws:iam::<account-id>:policy/gw230529-terraform-operator \
  --policy-document file://policies/terraform-operator.json \
  --set-as-default
```
