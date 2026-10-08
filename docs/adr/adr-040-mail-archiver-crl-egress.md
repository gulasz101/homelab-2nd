# ADR-040: Mail-Archiver needs HTTP (port 80) egress for certificate-revocation checks

## Status

Accepted — 2026-10-08 · Epic H2-145, step ST7 (H2-152). **Supersedes ADR-039**
(which wrongly concluded that .NET could not fetch the CRL and that the fix was
`IgnoreSelfSignedCert=true`; both the diagnosis and the decision were wrong — see
"Supersedes" below). Amends the egress model recorded in ADR-037.

## Context

Saving a Gmail IMAP account in Mail-Archiver failed reproducibly with the UI message
*"Connection to email server could not be established. Please check your settings and
ensure the server is reachable."* — and the account was never created
(`mail_archiver."MailAccounts"` stayed empty), because the app tests the connection
*before* persisting it.

The message blames the network; the failure is a **certificate-revocation check**, and
the reason the check fails is a **NetworkPolicy we wrote ourselves**.

The mechanism, verified from the live app pod:

- MailKit defaults `CheckCertificateRevocation = true`, which it maps to
  `X509RevocationMode.Online`. Mail-Archiver never overrides it.
- In `Online` mode, .NET/OpenSSL processes the chain's revocation data and **downloads
  the CA's CRL (and AIA issuer cert) over the certificate's `http://` distribution
  point**. Gmail's Google Trust Services cert points at `http://c.pki.goog/wr2/…crl`.
- Our `NetworkPolicy` for the app pod opened egress on `993` (IMAPS), `143` (IMAP),
  `443` (HTTPS/OIDC) and `53`/`5432` — **not port 80**. The CRL download therefore
  failed, the chain was flagged **`X509ChainStatusFlags.OfflineRevocation`**
  ("unable to get certificate CRL"), and the app's strict
  `ServerCertificateValidationCallback` rejected a perfectly valid certificate.

Live proof from the app pod:

```
# with port 80 blocked (the broken state)
$ bash -c 'echo > /dev/tcp/142.251.13.94/80'   -> Connection refused     (443, 993 -> open)

# with the CRL present, OpenSSL reports exactly what .NET sees:
$ openssl verify -crl_check -untrusted <intermediates> -CAfile <bundle> c1.pem
CN = imap.gmail.com
error 3 at 0 depth lookup: unable to get certificate CRL
error c1.pem: verification failed

$ openssl verify -crl_check -CRLfile wr2.crl -untrusted <intermediates> -CAfile <bundle> c1.pem
c1.pem: OK
```

Note how a *misleading* detail nearly hid this: `openssl s_client … -crl_check` still
reports "unable to get certificate CRL" even after port 80 is opened, because
`s_client` does not itself download CRLs — only .NET/OpenSSL's *chain* processing does.
So "s_client still fails" is **not** evidence that the fix did not work; the real
end-to-end check is the app's own connect path.

## Decision

**Open TCP/80 egress on the Mail-Archiver app pod's NetworkPolicy**, with a comment
explaining that it exists solely for certificate-revocation fetching — not for any
plaintext application traffic. Revert ADR-039's `MailSync__IgnoreSelfSignedCert=true`.

This is deliberately the *opposite* of the "just disable certificate checking"
reflex: the port is added so that **revocation checking succeeds**, keeping chain,
hostname and expiry validation fully enforced.

End-to-end verification (not just "the port is open"):

- A throwaway account row (bogus disposable password, no real credential) was inserted
  and picked up by the sync loop. The app logged:
  `Starting IMAP sync for account: ZZZ-crl-probe` → `SASL PLAIN authentication failed …
  Invalid credentials (Failure)`. In other words it **got through TLS and reached IMAP
  authentication** — the certificate wall is gone; only the fake password failed. The
  row was deleted afterwards.

## Consequences

**Positive**

- Gmail connect + save now work with **full** certificate validation intact.
- Port 80 egress is a small, well-understood hole that exists to *enable* a security
  control; it carries no application data (IMAP is 993/143, the tunnel hop is plain
  HTTP *inside* the cluster).
- The misleading-error trap is now documented so the next person reads the app's
  stdout instead of trusting the UI message.

**Negative**

- Any pod matching this policy can now make plaintext HTTP connections to arbitrary
  hosts on port 80. Accepted: the app only performs CRL/AIA fetches, and the
  alternative (disabling revocation checking) is worse.
- One more port to remember when this policy is copied to another service.

## Alternatives considered

1. **`IgnoreSelfSignedCert=true` (ADR-039).** Rejected and reverted. It would not have
   worked: Mail-Archiver's callback tolerates `UntrustedRoot | PartialChain |
   RevocationStatusUnknown`, but .NET sets **`OfflineRevocation`** for a failed CRL
   fetch on Linux, which the callback rejects. (Belt-and-braces: it also broadens what
   is accepted when it *does* return true.)
2. **A dedicated egress gateway / proxy that fetches revocation material.** Deferred,
   not rejected. It is the natural next tightening (allow 80 only to the CA hosts, or
   funnel revocation through a controlled proxy) and is exactly the "future egress
   gateway" note already carried in ADR-037.
3. **Pin the CRL or the certificate locally.** Rejected: Gmail rotates certs and CRLs
   constantly; a pinned trust anchor or CRL is a time bomb.
4. **Move to `NoCheck`** (fork the app to set `client.CheckCertificateRevocation=false`).
   Rejected as a first resort: it removes a working control to avoid a one-line
   NetworkPolicy change. Kept as the fallback if a future environment makes 80
   unopenable.

## When to revisit

- Tighten port 80 to the CA's CDP hosts (or introduce an egress proxy / egress gateway)
  — the moment this deployment grows a second IMAP provider or the network model gets
  stricter.
- If upstream Mail-Archiver ever adds a revocation-soft-fail flag that also covers
  `OfflineRevocation`, prefer that over the broad 80 egress.
- If MailKit/.NET changes its CRL-fetch behaviour or Gmail stops publishing an `http://`
  CRL DP.
