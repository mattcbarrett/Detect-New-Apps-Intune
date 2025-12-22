# Description

Aggregates new detected apps on Windows endpoints joined to Entra ID and managed by Intune. Sends a weekly email with the results.

# Prerequisites

Be sure you have an Azure subscription prior to executing the deployment script.

# Usage

Run deploy.ps1. You will be prompted for configuration variables during script execution.

# How does it work?

The Intune Management Extension collects a software inventory every 24 hours and uploads it to Intune. This tool relies on that data to create a differential of the detected apps list every day and write the results to CSV. Once a week, it aggregates those results and sends it in an email.

The deploy.ps1 script creates a storage container and function app in Azure that's configured with a timer trigger set to 15:00 UTC. The code then:

1. Fetches the Detected apps list for all endpoints from MS Graph's /deviceManagement/detectedApps endpoint and saves it to a JSON blob.
3. Retrieves the most recent previous Detected apps list from the same container.
4. Compares the apps list for each device and returns apps not present in the prior list. If there are results, save them to a separate blob in a separate container.
5. If it's $REPORT_DAY_OF_WEEK, fetch the prior $DAYS_TO_AGGREGATE days of results. Aggregate them and fetch a list of hostnames for each app from /deviceManagement/detectedApps/$appId/managedDevices.
6. Email the results and prune blobs older than $RETENTION_PERIOD.

# Why create this tool?

I've found satisfying the CIS 18 Controls 2.3 "Address Unauthorized Software" and 2.4 "Utilize Automated Software Inventory Tools" to be a challenge at small or under-resourced shops. I wanted to create a solution using existing tools (Intune) that a small operations team with a limited budget can use to provide better visbility on what applications are being brought into the environment.