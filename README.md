This repository contains example Terraform modules for installing and configuring Retool. For full documentation on all the ways you can deploy Retool on your own infrastructure, please see the [Setup Guide](https://github.com/tryretool/retool-onpremise).

Disclaimer: Please use these modules only if you're comfortable configuring Terraform.

# Prerequisites

- All modules have been test on **Hashicorp Terraform v1.3.7**
- The AWS Provider version is set to **v4.0**

# Usage

Navigate to your desired cloud provider + deployment module for specific configuration options.

# How to deploy
1. Make sure you're on the `production` workspace.
2. Run `tf apply`

# How to upgrade
1. Check the latest version of Retool on https://docs.retool.com/changelog/tags/self-hosted
2. Change the version number in the `main.tf` file of the ecs_retool_image on line 23.
3. Deploy
