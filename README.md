# jira-laps-webhook
Jira Service Desk request to Azure Automation to retrieve and rotate LAPS password

### What's the deal?
Traditionally, users had local admin passwords (mostly trusted Engineers who genuinely require it in order to do their jobs). Notwithstanding, this poses a security risk. Additionally, users would regularly forget to not let the password expire, resulting in unnecessary tickets to the IT team.
The requirement was to implement LAPS but also give the end user a relatively pain-free way of getting local admin rights should they need them. Lastly, improve tracking of local admin usage so that we can spot opportunities for user education, or analyse for abuse.

Here's the basic flow:
- User requests local admin password for their machine using the regular Jira Service Desk form. They can only request for their assigned machine to prevent naughtiness.
- Request is approved (optional)
- Jira sends webhook request to Azure Automation Runbook.
- The Runbook hands off the request to the local windows server
- Local windows server requests LAPS password
- Writes password to a designated section of Vault
- Jira ticket is resolved with a link to the secret in Vault. Only the requesting user has access to this entry in Vault.

In general, the process takes less than a minute. Any slowness is usually down to Azure's automation process.


### Requirements
 - Jira (tested with 8x, probably works with 7x, unlikely to work lower.
   than that) with Service Desk (technically optional, but not tested
   without) and JMWE (or similar)
  - Azure Automation Account
  - an internal Windows server
  - a user account that can read LAPS passwords from Active Directory
  - Hashicorp Vault (also optional if you tweak the code a little)

### Basic setup
- In Jira, create a new user property for each user. Call the property "computerName" and the value is the name of the computer the user has the ability to make a request for. This is relatively easy to bulk-update using the Jira API if you have a large number of users.
- Add a field called "Computer Name" to the appropriate screen(s) within Jira.
- Using JMWE (or similar), create a post-function that takes the user's computer name and inserts it into the computer name field when a ticket is created. The groovy below may help to pull the key you're looking for:
	- `ComponentAccessor.userPropertyManager.getPropertySetForUserKey(currentUser.key).getAsActualType("jira.meta.computerName")`

- In Azure, create a new Automation Account (or use an existing one). Add a new credential. This is the credential to log into jira and update the ticket. In my code, this user is called jira.no-reply@notarealcompany.com, and named in Azure as Jira Automation.
- Modify the powershell script:
	- **Line 26** - your custom field ID will almost certainly differ
	- **Lines 39 & 42**- adjust your jirauser to match what you set up
	- **Lines 49** - this is the transition ID for your Jira workflow (in my case moving from "To Do" to "In Progress". Adjust as appropriate.
	- **Lines 81 & 82** - adjust the vault login role/secret. If you don't want to use Vault, you could tweak the code to just punt the password back to the user in a jira comment. Please be aware of the security implications of doing this.
	- **Line 91** - adjust another jira workflow transition ID. In this case I'm transitioning from "In Progress" to "Resolved"
- There are of course other sections you may wish to tweak. The LAPS password is set to stop working at midnight the day of request. The message/comment that gets sent back to Jira almost certainly needs customising for your needs.
- Add your Runbook to Azure automation accounts. This is a PowerShell runbook.
- Set up a hybrid worker group to link your Automation Account Runbook with one or more internal servers. Ensure the "Run As" credential has enough access rights to pull LAPS passwords from AD.
- Add a webhook and copy the URL.
- In Jira, create a webhook that sends to your Azure Automation URL. Tweak the events as appropriate (i.e. set to trigger on a given state for a given Customer Request Type). Ensure "exclude body" is set to "no".
