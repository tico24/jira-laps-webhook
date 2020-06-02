Param
([object]$WebhookData)

# If runbook was called from Webhook, WebhookData will not be null.
if ($WebHookData){

    # Collect properties of WebhookData
    $WebhookName     =     $WebHookData.WebhookName
    $WebhookHeaders  =     $WebHookData.RequestHeader
    $WebhookBody     =     $WebHookData.RequestBody

    # Collect individual headers. Input converted from JSON.
    $From = $WebhookHeaders.From
    $Input = (ConvertFrom-Json -InputObject $WebhookBody)
    Write-Verbose "WebhookBody: $Input"
    Write-Output -InputObject ('Runbook started from webhook {0} by {1}.' -f $WebhookName, $From)
}
else
{
   Write-Error -Message 'Runbook was not started from Webhook' -ErrorAction stop
}

$jiraticketid = $Input.issue.key
Write-Output -InputObject ('Issue KEY {0}.' -f $jiraticketid)

$compName = $Input.issue.fields.customfield_10706
Write-Output -InputObject ('Computer Name {0}.' -f $compName)


  If(-not(Get-InstalledModule JiraPS -ErrorAction silentlycontinue)){
      Install-PackageProvider NuGet -Force;
      Set-PSRepository PSGallery -InstallationPolicy Trusted
      Install-Module JiraPS -Repository PSGallery -Confirm:$False -Force
  }

Import-Module AdmPwd.PS
Import-Module JiraPS

$jirauser = "jira.no-reply@notarealcompany.com"

Set-JiraConfigServer -Server 'https://planninginjira.notarealcompany.com'
$cred = Get-AutomationPSCredential -Name "Jira Automation"
New-JiraSession -Credential $cred

write-output "Performing password and Jira magic, please wait"

# Assign the jira ticket to the admin and move to In Progress
Set-JiraIssue -Issue $jiraticketid -Assignee $jirauser
Invoke-JiraIssueTransition -Issue $jiraticketid -Transition 1001

 # Push data to zabbix with the LAPS Request
Send-ZabbixTrap -z $Monitor_IP -p 10051 -s $hostname -k "workstation.laps[$hostname]" -o "$jiraticketid"

$tomorrow = (Get-Date).AddDays(1).ToString("dd/MM/yyyy")
$pwd = Reset-AdmPwdPassword -ComputerName $compName -WhenEffective $tomorrow -ErrorAction Stop 
$password = get-AdmPwdPassword $compName | Select -ExpandProperty Password
$expires = get-AdmPwdPassword $compName | Select -ExpandProperty ExpirationTimestamp | Get-Date -Format F

$email = Get-JiraIssue -key $jiraticketid |  Select -Expand Reporter | Select -Expand EmailAddress
$adusername = Get-ADUser -Filter * -Properties mail | Where-Object{$_.mail -like "$email"} | Select -ExpandProperty SamAccountName

$message = @"
Your temporary administrator password for $compName is now in Vault. You can obtain it through the command line:
{code:java}
vault login -method=ldap username=$adusername
vault kv get -field=password secret/$adusername/local-admin-pass
{code}
Or via the website:
https://secrets.notarealcompany.com/ui/vault/secrets/secret/show/$adusername/local-admin-pass

Please note that this password will stop working on $expires
"@

if (!$password) {
    # Move request to todo
    Invoke-JiraIssueTransition -Issue $jiraticketid -Transition 1091
    $message = "ERROR: Domain Controller returned an empty password. I need a human to intervene. The IT team will be along shortly"
    Add-JiraIssueComment -Comment $message -Issue $jiraticketid
    Write-Output $message

    } else {

    # Vault things - log into vault, create the secret
    $role_id="_VAULT_ROLE_ID_HERE_"
    $secret_id="_VAULT_SECRET_ID_HERE"
    $json = vault write -format=json auth/approle/login role_id=$role_id secret_id=$secret_id | Out-String | ConvertFrom-Json
    $vault_token = $json.auth.psobject.properties.Where({$_.name -eq "client_token"}).value
    vault login $vault_token
    vault kv put secret/$adusername/local-admin-pass username=.\AdministrativeUser password=$password expires=$expires
    vault kv metadata put -max-versions 1 secret/$adusername/local-admin-pass

    Add-JiraIssueComment -Comment $message -Issue $jiraticketid
    # Move the ticket to 'resolved'
    Invoke-JiraIssueTransition -Issue $jiraticketid -Transition 1021
    Write-Output $message
}