# Security policy

`agent-pr-flow` is security tooling — a set of hooks, scripts, and a CI workflow that gate how code
reaches a repository's trunk. Its guarantees, and their honest limits, are documented in
[docs/architecture.md](docs/architecture.md) (see especially *Threat model* and *What is mechanical
vs. what stays convention*). In short: the hooks are **defense-in-depth against agent mistakes and
drift, not a sandbox against a determined adversarial agent**, and `main-guard` is the server-side
backstop for whatever slips a client-side gate.

## Reporting a vulnerability

Please report suspected vulnerabilities **privately**, not as a public issue:

- Use GitHub's **[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)**
  on this repository (the **Security → Report a vulnerability** tab), which opens a private advisory
  visible only to the maintainer.

Please include: the affected file(s), a description of the weakness, and a minimal reproduction
(ideally a `test-hooks.sh`-style payload showing the bypass). If it's a hook-evasion, note whether
it requires deliberate obfuscation (accepted threat boundary) or works with an ordinary command
(a real defect worth fixing).

## Scope

In scope: bypasses of the enforcement mechanisms that work with **ordinary, non-obfuscated**
commands; command-injection or footguns in `install.sh` / the scripts; secret-scanner false
negatives on realistic inputs; anything that lets an out-of-process change reach trunk *undetected*
(i.e. also evading `main-guard`).

Out of scope (documented, accepted): deliberate whitespace/quoting obfuscation of a shell command
to evade a client-side hook; a human running `gh pr merge` in their own terminal; the spoofability
of agent-authored review verdicts (mitigated by the audit trail). See the architecture doc for why.
