# ADR-039: Mail-Archiver tolerates the .NET-on-Linux revocation-check soft failure (IgnoreSelfSignedCert=true)

> **⚠️ CORRECTED / SUPERSEDED by [ADR-040](adr-040-mail-archiver-crl-egress.md).**
> The diagnosis below is **wrong** and the decision was **reverted**. The assumption
> "the CRL URL is reachable and .NET simply cannot fetch it" was based on an invalid
> test (a probe pod that never actually received the NetworkPolicy). In reality the
> NetworkPolicy **blocked port 80**, so the CRL fetch genuinely failed — and setting
> `IgnoreSelfSignedCert=true` could not have helped anyway, because Mail-Archiver's
> callback tolerates `RevocationStatusUnknown` but **not `OfflineRevocation`**, which
> is the flag .NET actually sets on Linux. Kept for the record; see ADR-040 for the
> real cause and the fix. Commits: `caf94b0` (this ADR's decision), reverted by `273e68c`.

## Status

Superseded by ADR-040 — 2026-10-08. Originally: Accepted — 2026-10-08 · Epic H2-145,
step ST7 (H2-152). The text below is the original, uncorrected record.

## Context

Saving a Gmail IMAP account in Mail-Archiver failed reproducibly with the web
UI message *"Connection to email server could not be established. Please check
your settings and ensure the server is reachable."* — and the account was never
created (`mail_archiver."MailAccounts"` stayed empty), because the app tests the
connection **before** persisting and refuses to save a failing account.

The message says "server not reachable", but it is not a network problem. The
app logs show the real reason:

```
warn: MailArchiver.Services...ImapConnectionFactory[0]
      Certificate validation failed for IMAP server: RemoteCertificateChainErrors
fail: ...
      The server's SSL certificate could not be validated for the following reasons:
        • The server certificate has the following errors:
          • unable to get certificate CRL
        • An intermediate certificate has the following errors:
          • unable to get certificate CRL
 ---> System.Security.Authentication.AuthenticationException:
        The remote certificate was rejected by the provided RemoteCertificateValidationCallback.
```

The Gmail certificate is genuinely valid. Inside the running pod:

```
$ echo | openssl s_client -connect imap.gmail.com:993 -servername imap.gmail.com
Verify return code: 0 (ok)                     # default chain verification passes

$ echo | openssl s_client -connect imap.gmail.com:993 -servername imap.gmail.com -crl_check
Verify return code: 3 (unable to get certificate CRL)   # <- the .NET path
```

Three facts together produce the failure:

1. **.NET's `SslStream` cannot complete certificate revocation checking on
   Linux.** `X509Chain` on Linux runs with the equivalent of
   `X509RevocationMode.Online` and **hard-fails** when a CRL distribution point
   is unreachable, instead of degrading to the soft failure most stacks use.
   Documented upstream: dotnet/runtime #17906 and #81392 (both closed as
   unsolvable/expected). Gmail's Google Trust Services cert carries an `http://`
   CRL DP, so the chain reports `RevocationStatusUnknown / unable to get
   certificate CRL`.
2. **MailKit exposes no per-client switch to disable this.** The usual fix is
   `client.CheckCertificateRevocation = false`, but that property was **removed**
   in MailKit 4.x — there is no supported way for the app to force
   `X509RevocationMode.NoCheck` through `SslStream`.
3. **Mail-Archiver's certificate callback rejects the chain on that soft
   failure.** `ImapConnectionFactory.ServerCertificateValidationCallback`
   returns `false` whenever `MailSync.IgnoreSelfSignedCert=false` (the default).
   With the flag `true`, the callback tolerates a chain status limited to
   `UntrustedRoot | PartialChain | RevocationStatusUnknown` — exactly this case —
   while still rejecting expired certificates, hostname mismatches and genuine
   trust failures.

This is upstream bug **s1t5/mail-archiver#454** (open at the time of writing;
the identical Gmail symptom was reported and closed-as-never-fixed in #183).
We are already on the newest release (2609.1), so there is no version to
upgrade to.

## Decision

Set **`MailSync__IgnoreSelfSignedCert=true`** on the Mail-Archiver Deployment.

The variable name is misleading and the decision is explicitly *not* "trust any
certificate". The app's callback, read from source and covered by its own test
suite, applies this logic:

- chain errors limited to `UntrustedRoot | PartialChain | RevocationStatusUnknown`
  → **accepted**
- `NotTimeValid` (expired) → **rejected**
- `RemoteCertificateNameMismatch` (alone) → **accepted** (hostname tolerance)
- any other/unknown error → **rejected**

So the flag buys exactly what we need — tolerance of an unreachable revocation
check — without disabling hostname or expiry validation. The IMAP endpoint is
still pinned to `imap.gmail.com:993`, TLS is still negotiated, and the host
still has to present a certificate whose chain roots in a real CA.

This is a workaround for a platform limitation, not a preference. It is
recorded here (and in the manifest comment) precisely so the next person does
not have to rediscover why a "not reachable" error was cured by a
"self-signed certificate" flag.

## Consequences

**Positive**

- Gmail IMAP connection test succeeds → accounts can be saved → ST7 onboarding
  can proceed.
- The security posture is essentially unchanged: revocation checking was
  **never actually working** on this platform — it was failing closed with a
  false negative that blocked a valid certificate. Accepting the soft failure
  restores the intended behaviour (validate chain + hostname + expiry) rather
  than removing a working control.
- The flag's blast radius is small: it applies to the pre-save test and to all
  IMAP connections of a single-user archiver that only talks to Gmail.

**Negative**

- We lose the *ability* to fail on a genuinely revoked Google certificate. Given
  that .NET cannot perform revocation checking here at all, there was never a
  working control to lose.
- The same flag also tolerates a hostname mismatch and an untrusted self-signed
  root, which is broader than strictly required. Accepted because the app offers
  no finer-grained switch and the connection target is a fixed public server.

**Neutral**

- Should not need touching on rebuild: it is env in the Git-tracked Deployment,
  reconciled by Flux like everything else.

## Alternatives considered

1. **Pin the certificate or pin the CRL locally.** Rejected: Gmail rotates
   certificates and CRLs constantly; a pinned cert is a time bomb and a locally
   served CRL adds a serving dependency for no security gain.
2. **Run the container as root / add a custom CA.** Rejected: neither changes
   the .NET revocation path (the CA bundle is already present and correct), and
   running as root worsens the security posture for zero benefit.
3. **Switch the app to a different TLS stack / fork the validation callback.**
   Rejected: forking a fast-moving 2.1k-star upstream to carry a one-line change
   is a maintenance tax far larger than the workaround, and the upstream is
   already tracking the bug.
4. **Downgrade Mail-Archiver to a MailKit 3.x build** (which still had
   `CheckCertificateRevocation`). Rejected: no released image pins the old
   MailKit, and older releases carry other fixes we want.
5. **Give up on Gmail via Mail-Archiver.** Rejected: the whole epic exists to
   get out of Gmail; refusing a valid-certificate false-negative as a
   configuration problem would be the tail wagging the dog.

## When to revisit

Revisit if **any** of the following becomes true:

- Upstream s1t5/mail-archiver#454 ships a dedicated revocation setting (or any
  release exposes a `NoCheck` path) — then switch to that and drop this flag.
- `.NET` on Linux gains working CRL/OCSP checking with soft-fail semantics.
- The app is ever pointed at a server where a **real** revocation or hostname
  problem must be caught (i.e. it stops being Gmail-only) — at that point the
  broad tolerance of this flag becomes an actual risk and needs re-evaluation,
  including a possible pinned-CRL or egress-gateway approach.
