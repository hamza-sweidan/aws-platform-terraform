# 0002. S3 native state locking instead of DynamoDB

- **Status:** Accepted
- **Date:** 2026-09-23

## Context

Remote state needs a lock so two `apply` runs can't write the same state at
once. For years the S3 backend needed a DynamoDB table for that. Terraform
1.10 added S3-native locking (`use_lockfile`), which became GA in 1.11. The
DynamoDB arguments are deprecated.

## Decision

Use `use_lockfile = true` in every S3 backend. No DynamoDB table.

How it works: at the start of a locking operation Terraform writes
`<key>.tflock` with a conditional `PutObject` (`If-None-Match: *`). S3 only
lets that write succeed if the object doesn't exist, so the first writer wins
and everyone else gets a lock error that shows who holds the lock. The object
is deleted on unlock.

## Consequences

**Good**
- One resource, not two. There is no second service's IAM, encryption and
  backup to manage.
- The lock sits next to the state, under the same bucket policy, encryption and versioning.
- Requires Terraform >= 1.11, pinned via `required_version = "~> 1.16.0"`.

**Watch out for**
- IAM: principals need `s3:PutObject` and `s3:DeleteObject` on
  `<key>.tflock`, not just on the state key.
- Versioning: each lock and unlock leaves a noncurrent version of the
  `.tflock` object. The bootstrap lifecycle rule expires noncurrent versions
  so they don't pile up.
- A crashed run leaves the lock behind. Release it with
  `terraform force-unlock <ID>`, and only after confirming nobody else is running.
- The bootstrap bucket itself uses local state, the unavoidable chicken-and-egg.
