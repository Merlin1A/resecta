# Security Policy

Resecta is an on-device iOS redaction app. Because redaction is a security-sensitive operation, we take reports of vulnerabilities seriously and welcome good-faith security research.

## Supported versions

| Version | Supported |
| --- | --- |
| 1.0.x | Yes |
| Pre-release builds | No |

When reproducing a report, please use the synthetic test corpus bundled with the repository (the Hartwell loan-packet and sample bank statement fixtures) rather than real personal documents — reports should never contain real PII.

## Reporting a vulnerability

Please report suspected vulnerabilities through either of the following channels:

- **Email:** `security@resecta.app`.
- **GitHub Security Advisories:** open a private advisory on the Resecta repository's *Security* tab (available once the repository is public).

Please **do not** file public GitHub issues for security reports until the issue has been addressed and coordinated disclosure has been agreed upon.

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

## Scope

**In scope:**

- The Resecta iOS application (all code in this repository).
- Bundled first-party Swift packages (e.g., `Packages/RedactionEngine/`).
- Any vulnerability that could undermine the redaction, verification, metadata, or on-device-only properties the app is designed to provide.

**Out of scope:**

- Third-party services or dependencies outside this repository.
- Social-engineering attacks against contributors or users.
- Issues requiring a compromised device, compromised Apple ID, or physical access to an unlocked device.
- Missing security headers on external websites not controlled by this project.

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

- Publish a changelog entry referencing the fix (CVE assignment where appropriate).
- Credit the reporter, unless anonymity was requested.
- Coordinate public disclosure after the fix is available to users.

Thank you for helping keep Resecta and its users safe.
