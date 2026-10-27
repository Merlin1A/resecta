# Security Policy

Resecta is an on-device iOS redaction app. Redaction is a security-sensitive operation; vulnerability reports and good-faith security research are welcome.

The threat model this policy is written against — what the app protects, whom it protects it from, where its trust boundaries lie, and what it does not claim to handle — is published in [`THREAT-MODEL.md`](./THREAT-MODEL.md), together with a dated table of the project's security posture and how to check each line.

## Supported versions

| Version | Supported |
| --- | --- |
| Current App Store release | Yes |
| Earlier releases | Best effort |
| Pre-release builds | No |

When reproducing a report, please use the bundled sample document (Home → Try the Sample, `Resources/SampleDocument.pdf`) or the synthetic sample bank statement in the engine's test fixtures (`Packages/RedactionEngine/Tests/RedactionEngineTests/Fixtures/TestResources/sample-bank-statement.pdf`) rather than real personal documents — reports should never contain real PII.

## Verifying a release tag

Release tags are signed with an SSH key. [`.github/allowed_signers`](./.github/allowed_signers) lists that key under the project's security contact, so `git tag -v` can check a tag against it:

```sh
git clone https://github.com/Merlin1A/resecta.git && cd resecta
git config gpg.ssh.allowedSignersFile .github/allowed_signers
git tag -v v1.3.0
```

The first line of the output reads:

```
Good "git" signature for security@resecta.app with ED25519 key SHA256:WVeaeef/Q5rt1Bni6HwZCTpialq2h0FEGeJY4v3aKOg
```

Release tags from `v1.2.0` on are signed with this key; `v1.0.0` is a signed annotated tag that verifies the same way, and `v1.1.0` is an unsigned lightweight tag. The same key is published at `https://api.github.com/users/Merlin1A/ssh_signing_keys`.

The key file was added after the `v1.2.0` tag, so for `v1.0.0` and `v1.2.0` the recipe runs from a clone of `main`, as above; from `v1.3.0` the file is in the tagged tree itself, so that tag also verifies against the key file it carries.

## Reporting a vulnerability

Please report suspected vulnerabilities through either of the following channels:

- **Email:** `security@resecta.app`.
- **GitHub Security Advisories:** open a private advisory on the Resecta repository's *Security* tab.

Please **do not** file public GitHub issues for security reports until the issue has been addressed and coordinated disclosure has been agreed upon.

Plain email is the default channel. If a report needs more confidentiality than email offers, use a private GitHub Security Advisory: it keeps the report restricted to you and the maintainer without a separate encryption key or an out-of-band verification step. No PGP key is published for this address.

The machine-readable pointer to this policy is `https://resecta.app/.well-known/security.txt`.

### What to include

A useful report generally contains:

- A description of the issue and its impact on Resecta users or their documents.
- Steps to reproduce, including the affected version, iOS version, and build configuration.
- Any proof-of-concept artifacts, logs, or screenshots.
- Your preferred credit line (or a request to remain anonymous).

### What to expect

- **Acknowledgement:** within 7 days of receipt.
- **Triage update:** within 30 days of acknowledgement.
- **Disclosure coordination:** we will work with you on a disclosure timeline. We request a **90-day embargo** from the date of first report before public disclosure, and will aim in good faith to have a fix ready within that window — Resecta is maintained on a best-effort basis, so this is an intention, not a guarantee. If additional time is needed, we will communicate early. <!-- LegalPhrases:safe -->

### How reports are classed

Triage orders reports by what the issue would let an adversary do, in this order, from most to least serious:

1. Content recoverable from a file the app presented as redacted, by whoever receives that file.
2. Original document content, or text you typed into the app, left on the device beyond the editing session where it can be read from a backup or a locked device.
3. A crafted document that makes the app export something under-redacted while reporting a pass, or that crashes or exhausts it.
4. A public claim about the app that is false.

The timelines above apply to every class; the order sets what is worked on first.

## Scope

**In scope:**

- The Resecta iOS application (all code in this repository).
- Bundled first-party Swift packages (e.g., `Packages/RedactionEngine/`).
- Any vulnerability that could undermine the redaction, verification, metadata, or on-device-only properties the app is designed to provide.

The detection-data pipeline ([`resecta-datapipeline`](https://github.com/Merlin1A/resecta-datapipeline)) and the sample-document generator ([`resecta-sample-doc`](https://github.com/Merlin1A/resecta-sample-doc)) carry their own security policies; a report about the data the app bundles is welcome in either place.

**Out of scope:**

- Third-party services or dependencies outside this repository.
- Social-engineering attacks against contributors or users.
- Issues requiring a compromised device, compromised Apple ID, or physical access to an unlocked device.
- Missing security headers on external websites not controlled by this project.

## What this project is not

- **Not audited.** No third-party security audit has been performed to date.
- **Not a bounty program.** There is no bug bounty; reporters are credited, as described under Coordinated disclosure below.
- **Not a compliance or certification product.** Resecta makes no compliance claims and holds no certification against any standard.

## Safe harbor for good-faith research

Resecta's safe-harbor position is informed by the following authorities:

- **DOJ Framework for a Vulnerability Disclosure Program for Online Systems** (July 2017), which recommends organizations state that activities conducted consistent with the policy constitute "authorized" conduct under the Computer Fraud and Abuse Act.
- **DOJ CFAA Charging Policy**, revised May 19, 2022, directing federal prosecutors to decline prosecution of good-faith security research (policy guidance, not statute).
- **CISA Binding Operational Directive 20-01** (Sept. 2, 2020), which required all U.S. federal civilian agencies to publish vulnerability disclosure policies with authorization and safe-harbor language.
- **Van Buren v. United States**, 593 U.S. 374 (2021), adopting a "gates-up-or-down" inquiry for CFAA authorization.

Consistent with that guidance:

1. We consider security research conducted in accordance with this policy to be **authorized** under the Computer Fraud and Abuse Act (18 U.S.C. § 1030) and analogous state laws, and we will not pursue civil action or report such research to law enforcement for accidental, good-faith violations of this policy.
2. We will work with you to understand and resolve issues promptly, and will recognize your contribution publicly if you are the first to report a previously unknown issue and we make a code or configuration change based on your report.

### What "good faith" means here

To stay within this safe harbor, researchers are expected to:

- Make a reasonable, good-faith effort to avoid privacy violations, destruction of data, service disruption, or degradation of the experience for other users.
- Use only the accounts, devices, or documents you own (or have explicit permission to use) when testing.
- Keep any data obtained through a vulnerability confidential until Resecta has had a reasonable opportunity to address the issue.
- Stop testing and report immediately if you encounter any user data that is not yours.
- Not exploit a vulnerability beyond the minimum necessary to demonstrate the issue.

### Limitations of this promise

This safe harbor is a commitment by the Resecta project only. It **cannot bind third parties or law enforcement**, and it does not waive any rights of any other party. It does not authorize:

- Actions that violate applicable laws other than those covered above.
- Testing against systems you do not own or are not authorized to test (for example, the App Store, Apple's servers, or any third-party service).
- Any activity that would compromise the privacy or property of other Resecta users.

Nothing in this policy is legal advice, and nothing here creates an attorney-client relationship.

## Coordinated disclosure

When a reported issue is resolved, we will:

- Ship the fix in a release and record it in [`CHANGELOG.md`](./CHANGELOG.md) under that release's `Security` heading, with the version number; the date that version became available on the App Store is the date the fix reached users.
- Publish a GitHub security advisory for the repository when the report warrants one, and request a CVE through GitHub's CNA for it.
- Credit the reporter, unless anonymity was requested.
- Coordinate public disclosure after the fix is available to users.

The App Store offers only the current version, so a fix reaches you as an update; there is no patched older version to install, and an earlier version keeps the issue until you update (see Supported versions above).

## Advisory history

No security advisories have been published for Resecta as of this document's last update. The GitHub API's `repos/Merlin1A/resecta/security-advisories` lists the published ones and answers without a login. Fixes that came out of the project's own security reviews are recorded in [`CHANGELOG.md`](./CHANGELOG.md), under a release's `Security` heading where it has one.

Thank you for helping keep Resecta and its users safe.
