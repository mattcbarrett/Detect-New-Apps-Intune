# Description

Detects newly installed applications on endpoints joined to Intune and sends a weekly email with the results.

# Usage

Run deploy.ps1. You will be prompted for configuration variables during script execution.

# How does it work?

The Intune Management Extension Agent collects a software inventory every 24 hours and uploads it to Intune. This tool relies on that data to create a differential of the detected apps list every day and write the results to CSV. Once a week, it aggregates those results and sends it in an email.

The deploy.ps1 script creates the appropriate resources in Azure and deploys the code to a Function App that's configured with a timer trigger set to 15:00 UTC. The code then:

1. Fetches the Detected apps list for all endpoints from MS Graph's /deviceManagement/detectedApps endpoint.
2. Saves the list to CSV in an Azure Storage container.
3. Retrieves the most recent previous Detected apps list from the same container. The list must be less than or equal to 1 day old.
4. Generates a diff of the two files. If there are results, save them to a 2nd container in Azure.
5. If it's $REPORT_DAY_OF_WEEK, fetch the prior $DAYS_TO_AGGREGATE days of diff results. Aggregate them and fetch a list of hostnames for each app from /deviceManagement/detectedApps/$appId/managedDevices.
6. Email the results and prune CSVs older than $RETENTION_PERIOD.

# Why create this tool?

I wanted a way to satisfy the CIS 18 Controls 2.3 "Address Unauthorized Software" and 2.4 "Utilize Automated Software Inventory Tools" using existing data from Intune. Just a simple weekly summary of new apps that provides visibility and allows action to be taken if necessary. 

# Troubleshooting

Azure Functions Core Tools doesn't always like authenticating via the Azure Powershell SDK. If you get an error from the func publish command, try installing the [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest), authenticating via "az login," and executing the func publish command on line 141 of deploy.ps1 again.

