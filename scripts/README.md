# Scripts

## Overview

This repository contains scripts for the deployment of the contracts in this repository.

As the Cairo version is upgraded over time, previously executed scripts and their state files have been removed to improve maintainability and clean up the workspace.

## Archived Files

| File Name/Pattern | Cairo Version | Description | Access Tag | Comments |
|-------------------|---------------|-------------|------------|----------|
| `deployment/src/deploy_mainnet.cairo` | `v2.6.5` | Deployment of Opus on Mainnet | `v1.1.0` | Use `v1.0.0` for mainnet launch deployment |
| `deployment/src/deploy_sepolia.cairo` | `v2.6.5` | Deployment of Opus on Sepolia | `v1.1.0` | |
| `deployment/src/deploy_oracles_v2_mainnet.cairo` | `v2.6.5` | Deployment of `v1.1.0` of Seer module and Ekubo fallback on Mainnet | `v1.1.0` | |
| `deployment/src/deploy_oracles_v2_sepolia.cairo` | `v2.6.5` | Deployment of `v1.1.0` of Seer module on Sepolia | `v1.1.0` | |

## Accessing Archived Files
All archived files can be accessed by checking out earlier release tags:

```bash
# To view the repository with all removed files intact
git checkout [tag-name]

# Example
git checkout v1.1.0
```
