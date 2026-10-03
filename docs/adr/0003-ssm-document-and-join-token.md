# 0003 - SSM document format and the kubeadm join token

**Status:** accepted, 2026-10-03
**Relates to:** `infra/modules/platform-bootstrap`, `infra/modules/cluster/templates/control-plane.sh.tftpl`

Three unrelated-looking failures in one day, all of which produced errors that
pointed at the wrong thing. Recorded together because they share a lesson: the
error is a symptom of the *shape* of the request, not of the part you were
thinking about.

## 1. The kubeadm join token was empty

`kubeadm token create` on Kubernetes 1.36 prints a **single** whitespace-delimited
field:

```
$ kubeadm token create --ttl 40m
vw9sia.rcfww8ho6qxpc0s5
```

One field: `<id>.<secret>`. Older releases printed `<id> <secret> <expiry>`. The
publisher in `control-plane.sh.tftpl` parsed two whitespace fields, so `$TOKEN` was
always empty.

The guard below it caught it and logged `kubeadm token create failed` on every
timer run - so nothing bad was *published*. But a join command with a bare
`--token` had already been written to SSM by an earlier run, and the guard's job
was to refuse to overwrite it with something worse. Every worker that booted after
that read the stale command, failed to parse a token, exited non-zero, and never
joined. The ASG replaced it with an identical instance, which read the same stale
command and lost the same race.

Two changes:

- The publisher accepts both shapes and normalises to the `id.secret` form that
  `kubeadm join --token` takes, keeping the bare id for revocation.
- The worker treats an unparseable command as "not ready yet" and retries inside
  its wait loop rather than exiting. An ASG that replaces an instance over a
  transient parameter read just relaunches into the same race.

## 2. `kubeadm join` was passed the wrong flags

The worker script had `--control-plane-endpoint`, which only exists on
`kubeadm init`. On 1.36:

```
error: unknown flag: --control-plane-endpoint
```

Removing it exposed the second half of the bug, which is worse: the endpoint is a
**positional** argument, `kubeadm join <api-server-endpoint>`. Without it, the
failure is not an unknown flag but

```
error: discovery: Invalid value: "": bootstrapToken or file must be set
```

which names the token. The token was correct. `--token` was on the command line
and visible in the trace. The error is about a field in a config struct kubeadm
builds after argument parsing fails to find an endpoint, and it reports the first
field it validates as empty rather than the thing that caused the problem.

## 3. SSM rejected the documented document format

`aws_ssm_document` with `mainType` + `content.runtimeConfig` - the shape in every
AWS example - fails:

```
InvalidDocumentContent: Unknown property "content"
InvalidDocumentContent: Unknown property "runtimeConfig"
InvalidDocumentContent: Unknown property "mainType"
```

Bisecting the accepted key set against `ap-south-1` gives the answer: the endpoint
wants the **legacy `mainSteps` shape**, under any schema version from 2.0 up:

```json
{
  "schemaVersion": "2.2",
  "description": "...",
  "parameters": {},
  "mainSteps": [
    {
      "action": "aws:runShellScript",
      "name": "bootstrapPlatform",
      "inputs": { "runCommand": ["<whole script, one entry>"] }
    }
  ]
}
```

`mainSteps` is required; every attempt without it returns
`Missing "mainSteps" in the document.`

The script must be a single `runCommand` entry. Splitting it into one entry per
line would give every line its own shell and its own exit code, so `set -e` would
only ever apply within a line.

## Lesson

All three errors name something that is present and correct. In each case the
useful information was in the *shape* of the request - two fields where the API
wants one, a flag that belongs to a different subcommand, a document envelope the
endpoint does not accept - and the message pointed at a nearby value instead.

The provider-side equivalent from the same day: `aws_ssm_association` in provider
v6 made `association_id` computed and moved the target to a `targets` block, and
`data.aws_acm_certificate` exports `arn` as computed only. Both fail with a message
that describes the argument rather than the replacement.

## Consequences

- The control plane's user data is at 16,384 bytes, EC2's limit, and
  `user-data-guard.tf` fails the plan when it crosses. Comment blocks in
  `control-plane.sh.tftpl` are deliberately short; rationale lives in
  `control-plane.tf` instead.
- `templatefile` claims every `${...}` in a template before bash sees it, so bash
  parameter expansion (`${VAR:-default}`) has to be written `$${VAR:-default}`.
  Three separate template errors during this work were all this.
