---
description: Information about Opus' security processes
---

# Security

If you would like to reach out to us regarding a potential vulnerability, please reach out to us at engineering@opus.money

## Security assumption

Opus as a protocol hinges on the critical assumption that the admin for its smart contracts is honest. Other than the admin, access control should be granted to smart contracts of Opus only, and not to any other users.

A compromised or malicious admin can cause catastrophic damage across the entire protocol.

It is a conscious design decision that this role is not behind a time lock. Priority is given to the ability to rapidly update and iterate on existing modules and components without interruption. It also avoids downtime whenever there is a bug or security vulnerability that needs to be fixed.

Trusting the admin to be honest is a prerequisite to trusting Opus' smart contracts.
