<#
.SYNOPSIS
    This sample automation runbook onboards an Azure VM for either the Update or ChangeTracking (which includes Inventory) solution.
    It requires an existing Azure VM to already be onboarded to the solution as it uses this information to onboard the
    new VM to the same Log Analytics workspace and Automation Account.
    This Runbook needs to be run from the Automation account that you wish to connect the new VM to.

.DESCRIPTION
    This sample automation runbook onboards an Azure VM for either the Update or ChangeTracking (which includes Inventory) solution.
    It requires an existing Azure VM to already be onboarded to the solution as it uses this information to onboard the
    new VM to the same Log Analytics workspace and Automation Account.
    This Runbook needs to be run from the Automation account that you wish to connect the new VM to.

.PARAMETER VMSubscriptionId
    The name subscription id where the new VM to onboard is located.
    This will default to the same one as the workspace if not specified. If you
    give a different subscription id then you need to make sure the RunAs account for
    this automation account is added as a contributor to this subscription also.

.PARAMETER VMResourceGroupName
    Required. The name of the resource group that the VM is a member of.

.PARAMETER VMName
    Required. The name of a specific VM that you want onboarded to the Updates or ChangeTracking solution

.PARAMETER SolutionType
    Required. The name of the solution to onboard to this Automation account.
    It must be either "Updates" or "ChangeTracking". ChangeTracking also includes the inventory solution.

.PARAMETER UpdateScopeQuery
    Optional. Default is true. Indicates whether to add this VM to the list of computers to enable for this solution.
    Solutions enable an optional scope configuration to be set on them that contains a query of computers
    to target the solution to. If you are calling this Runbook from a parent runbook that is onboarding
    multiple VMs concurrently, then you will want to set this to false and then do a final update of the
    search query with the list of onboarded computers to avoid any possible conflicts that this Runbook
    might do when reading, adding this VM, and updating the query since multiple versions of this Runbook
    might try and do this at the same time if run concurrently.

.NOTES
    AUTHOR: Automation Team
    Contibutor: Morten Lerudjordet
    LASTEDIT: February 13th, 2019
#>
#Requires -Version 5.0
Param (
    [Parameter(Mandatory = $False)]
    [Object]$WebHookData
)
try
{
    $RunbookName = "Enable-AutomationSolutionWebHook"
    Write-Output -InputObject "Starting Runbook: $RunbookName at time: $(get-Date -format r).`nRunning PS version: $($PSVersionTable.PSVersion)`nOn host: $($env:computername)"

    $VerbosePreference = "silentlycontinue"
    Import-Module -Name AzureRM.Profile, AzureRM.Automation, AzureRM.OperationalInsights, AzureRM.Compute, AzureRM.Resources -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to load needed modules for Runbook, check that AzureRM.Automation, AzureRM.OperationalInsights, AzureRM.Compute and AzureRM.Resources is imported into Azure Automation" -ErrorAction Stop
    }
    $VerbosePreference = "Continue"

    #region Variables
    ############################################################
    #   Variables
    ############################################################
    $LogAnalyticsAgentExtensionName = "OMSExtension"
    $MMAApiVersion = "2018-10-01"
    $WorkspacesApiVersion = "2017-04-26-preview"
    $SolutionApiVersion = "2017-04-26-preview"
    #endregion

    if($Null -ne $WebHookData)
    {
        if($Null -ne $WebhookData.RequestBody)
        {
            $ObjectData = ConvertFrom-Json -InputObject $WebhookData.RequestBody
            if($Null -ne $ObjectData.VMSubscriptionId)
            {
                $VMSubscriptionId = $ObjectData.VMSubscriptionId
            }
            else
            {
                Write-Error -Message "Missing VMSubscriptionId in input data" -ErrorAction Stop
            }
            if($Null -ne $ObjectData.VMResourceGroupName)
            {
                $VMResourceGroupName = $ObjectData.VMResourceGroupName
            }
            else
            {
                Write-Error -Message "Missing VMResourceGroupName in input data" -ErrorAction Stop
            }
            if($Null -ne $ObjectData.VMName)
            {
                $VMName = $ObjectData.VMName
            }
            else
            {
                Write-Error -Message "Missing VMName in input data" -ErrorAction Stop
            }
            if($Null -ne $ObjectData.SolutionType)
            {
                $SolutionType = $ObjectData.SolutionType
            }
            else
            {
                Write-Warning -Message "Missing SolutionType in input data, using default set to Updates"
                $SolutionType = "Updates"
            }
            if($Null -ne $ObjectData.UpdateScopeQuery)
            {
                $UpdateScopeQuery = $ObjectData.UpdateScopeQuery
            }
            else
            {
                Write-Verbose -Message "Missing UpdateScopeQuery in input data, using default set to True"
                $UpdateScopeQuery = $True
            }
        }
        else
        {
            Write-Error -Message "Input data in request body is empty " -ErrorAction Stop
        }

    }
    else
    {
        Write-Error -Message "Input data from webhook is empty" -ErrorAction Stop
    }

    # Authenticate to Azure
    $ServicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
    $Null = Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $ServicePrincipalConnection.TenantId `
        -ApplicationId $ServicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to connect to Azure" -ErrorAction Stop
    }

    # Set subscription to work against
    $SubscriptionContext = Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to set azure context to subscription for AA" -ErrorAction Stop
    }

    if ($Null -eq $VMSubscriptionId)
    {
        # Use the same subscription as the Automation account if not passed in
        $NewVMSubscriptionContext = Set-AzureRmContext -SubscriptionId $ServicePrincipalConnection.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription for AA" -ErrorAction Stop
        }
        Write-Verbose -Message "Creating azure VM context using subscription: $($NewVMSubscriptionContext.Subscription.Name)"

    }
    else
    {
        # VM is in a different subscription so set the context to this subscription
        $NewVMSubscriptionContext = Set-AzureRmContext -SubscriptionId $VMSubscriptionId -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to set azure context to subscription where VM is. Make sure AA RunAs account has contributor rights" -ErrorAction Stop
        }
        Write-Verbose -Message "Creating azure VM context using subscription: $($NewVMSubscriptionContext.Subscription.Name)"
        # Register Automation provider if it is not registered on the subscription
        $AutomationProvider = Get-AzureRMResourceProvider -ProviderNamespace Microsoft.Automation `
            -AzureRmContext $NewVMSubscriptionContext |  Where-Object {$_.RegistrationState -eq "Registered"}
        if ($Null -eq $AutomationProvider)
        {
            $ObjectOutPut = Register-AzureRmResourceProvider -ProviderNamespace Microsoft.Automation -AzureRmContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to register Microsoft.Automation provider in: $($NewVMSubscriptionContext.Subscription.Name)" -ErrorAction Stop
            }
        }
    }

    # Will try to find an already onboarded VM in both AA subscription and VM subscription
    # TODO: More depth on the subscription the logic uses to find an existing VM with OMSExtension installed on
    $AzureRmSubscriptions = Get-AzureRmSubscription | Where-Object {$_.Name -eq $NewVMSubscriptionContext.Subscription.Name -or $_.Name -eq $SubscriptionContext.Subscription.Name}

    if($Null -ne $AzureRmSubscriptions)
    {
        # Run through each until a VM with Microsoft Monitoring Agent is found
        $SubscriptionCounter = 0
        foreach ($AzureRMsubscription in $AzureRMsubscriptions)
        {
            # Set subscription context
            $OnboardedVMSubscriptionContext = Set-AzureRmContext -SubscriptionId $AzureRmSubscription.SubscriptionId -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to set azure context to subscription: $($AzureRmSubscription.Name)" -ErrorAction Continue
                $oErr = $Null
            }
            if ($Null -ne $OnboardedVMSubscriptionContext)
            {
                # Find existing VM that is already onboarded to the solution.
                $VMExtensions = Get-AzureRmResource -ResourceType "Microsoft.Compute/virtualMachines/extensions" -AzureRmContext $OnboardedVMSubscriptionContext | Where-Object {$_.Name -like "*/$LogAnalyticsAgentExtensionName"}

                # Find VM to use as template
                if ($Null -ne $VMExtensions)
                {
                    Write-Verbose -Message "Found $($VMExtensions.Count) VM(s) with Microsoft Monitoring Agent installed"
                    # Break out of loop if VM with Microsoft Monitoring Agent installed is found in a subscription
                    break
                }
            }
            $SubscriptionCounter++
            if ($SubscriptionCounter -eq $AzureRmSubscriptions.Count)
            {
                Write-Error -Message "Did not find any VM with Microsoft Monitoring Agent already installed. Install at least one in a subscription the AA RunAs account has access to" -ErrorAction Stop
            }
        }
        $VMCounter = 0
        foreach ($VMExtension in $VMExtensions)
        {
            if ($Null -ne $VMExtension.Name -and $Null -ne $VMExtension.ResourceGroupName)
            {
                $ExistingVMExtension = Get-AzureRmVMExtension -ResourceGroup $VMExtension.ResourceGroupName -VMName ($VMExtension.Name).Split('/')[0] `
                    -AzureRmContext $OnboardedVMSubscriptionContext -Name ($VMExtension.Name).Split('/')[-1]
            }
            if ($Null -ne $ExistingVMExtension)
            {
                Write-Verbose -Message "Retrieved extension config from VM: $($ExistingVMExtension.VMName)"
                # Found VM with Microsoft Monitoring Agent installed
                break
            }
            $VMCounter++
            if ($VMCounter -eq $VMExtensions.Count)
            {
                Write-Error -Message "Failed to find an already onboarded VM with the Microsoft Monitoring Agent installed (Log Analytics) in subscription: $($NewVMSubscriptionContext.Subscription.Name), $($SubscriptionContext.Subscription.Nam)" -ErrorAction Stop
            }
        }
    }
    else
    {
        Write-Error -Message "Make sure the AA RunAs account has contributor rights on all subscriptions in play." -ErrorAction Stop
    }
    # Check if the existing VM is already onboarded
    if ($ExistingVMExtension.PublicSettings)
    {
        $PublicSettings = ConvertFrom-Json $ExistingVMExtension.PublicSettings
        if ($Null -eq $PublicSettings.workspaceId)
        {
            Write-Error -Message "This VM: $($ExistingVMExtension.VMName) is not onboarded. Please onboard first as it is used to collect information" -ErrorAction Stop
        }
        else
        {
            Write-Verbose -Message "VM: $($ExistingVMExtension.VMName) is correctly onboarded and can be used as template to onboard: $VMName"
        }
    }
    else
    {
        Write-Error -Message "Public settings for VM extension is empty" -ErrorAction Stop
    }

    # Get information about the workspace
    $WorkspaceInfo = Get-AzureRmOperationalInsightsWorkspace -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr `
        | Where-Object {$_.CustomerId -eq $PublicSettings.workspaceId}
    if ($oErr)
    {
        Write-Error -Message "Failed to retrieve Operational Insight workspace info" -ErrorAction Stop
    }
    if ($Null -ne $WorkspaceInfo)
    {
        # Workspace information
        $WorkspaceResourceGroupName = $WorkspaceInfo.ResourceGroupName
        $WorkspaceName = $WorkspaceInfo.Name
        $WorkspaceResourceId = $WorkspaceInfo.ResourceId
    }
    else
    {
        Write-Error -Message "Failed to retrieve Operational Insights Workspace information" -ErrorAction Stop
    }

    # Get the saved group that is used for solution targeting so we can update this with the new VM during onboarding..
    $SavedGroups = Get-AzureRmOperationalInsightsSavedSearch -ResourceGroupName $WorkspaceInfo.ResourceGroupName `
        -WorkspaceName $WorkspaceInfo.Name -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to retrieve Operational Insight saved groups info" -ErrorAction Stop
    }
    Write-Verbose -Message "Retrieving VM with following details: RG: $VMResourceGroupName, Name: $VMName, SubName: $($NewVMSubscriptionContext.Subscription.Name)"
    # Get details of the new VM to onboard.
    $NewVM = Get-AzureRMVM -ResourceGroupName $VMResourceGroupName -Name $VMName -Status `
        -AzureRmContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr | Where-Object {$_.Statuses.code -match "running"}
    if ($oErr)
    {
        Write-Error -Message "Failed to retrieve VM status data for: $VMName" -ErrorAction Stop
    }

    # Verify that VM is up and running before installing extension
    if ($Null -eq $NewVM)
    {
        Write-Error -Message "VM: $($NewVM.Name) is not running and can therefore not install extension" -ErrorAction Stop
    }
    else
    {
        $NewVM = Get-AzureRMVM -ResourceGroupName $VMResourceGroupName -Name $VMName `
            -AzureRmContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to retrieve VM data for: $VMName" -ErrorAction Stop
        }
        if ($Null -ne $NewVM)
        {
            # New VM information
            $VMResourceGroupName = $NewVM.ResourceGroupName
            $VMName = $NewVM.Name
            $VMLocation = $NewVM.Location
            $VMResourceId = $NewVM.Id
            $VMIdentityRequired = $false
        }
        else
        {
            Write-Error -Message "Failed to retrieve VM data for: $VMName" -ErrorAction Stop
        }

    }

    # Check if the VM is already onboarded to the MMA Agent and skip if it is
    $Onboarded = Get-AzureRmVMExtension -ResourceGroup $VMResourceGroupName  -VMName $VMName `
        -Name $LogAnalyticsAgentExtensionName -AzureRmContext $NewVMSubscriptionContext -ErrorAction SilentlyContinue -ErrorVariable oErr
    if ($oErr)
    {
        if($oErr.Exception.Message -match "ResourceNotFound")
        {
            # VM does not have OMS extension installed
            $Onboarded = $Null
        }
        else
        {
            Write-Error -Message "Failed to retrieve extension data from VM: $VMName" -ErrorAction Stop
        }

    }

    if ($Null -eq $Onboarded)
    {

        # Set up MMA agent information to onboard VM to the workspace
        if ($NewVM.StorageProfile.OSDisk.OSType -eq "Linux")
        {
            $MMAExentsionName = "OmsAgentForLinux"
            $MMAOStype = "OmsAgentForLinux"
            $MMATypeHandlerVersion = "1.4"
#Region Linux ARM Template
            # URL of linux template: https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/createMmaWindowsV3.json
            $ArmTemplate = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "vmName": {
            "defaultValue": "",
            "type": "String"
        },
        "vmLocation": {
            "defaultValue": "",
            "type": "String"
        },
        "vmResourceId": {
            "defaultValue": "",
            "type": "String"
        },
        "vmIdentityRequired": {
            "defaultValue": "false",
            "type": "Bool"
        },
        "workspaceName": {
            "defaultValue": "",
            "type": "String"
        },
        "workspaceId": {
            "defaultValue": "",
            "type": "String"
        },
        "workspaceResourceId": {
            "defaultValue": "",
            "type": "String"
        },
        "mmaExtensionName": {
            "defaultValue": "",
            "type": "String"
        },
        "apiVersion": {
            "defaultValue": "2015-06-15",
            "type": "String"
        },
        "workspacesApiVersion": {
            "defaultValue": "2017-04-26-preview",
            "type": "String"
        },
        "OStype": {
            "defaultValue": "",
            "type": "String"
        },
        "typeHandlerVersion": {
            "defaultValue": "",
            "type": "String"
        }
    },
    "variables": {
        "vmIdentity": {
            "type": "SystemAssigned"
        }
    },
    "resources": [
        {
            "type": "Microsoft.Compute/virtualMachines",
            "name": "[parameters('vmName')]",
            "apiVersion": "[parameters('apiVersion')]",
            "location": "[parameters('vmLocation')]",
            "identity": "[if(parameters('vmIdentityRequired'), variables('vmIdentity'), json('null'))]",
            "resources": [
                {
                    "type": "extensions",
                    "name": "[parameters('mmaExtensionName')]",
                    "apiVersion": "[parameters('apiVersion')]",
                    "location": "[parameters('vmLocation')]",
                    "properties": {
                        "publisher": "Microsoft.EnterpriseCloud.Monitoring",
                        "type": "[parameters('OStype')]",
                        "typeHandlerVersion": "[parameters('typeHandlerVersion')]",
                        "autoUpgradeMinorVersion": "true",
                        "settings": {
                            "workspaceId": "[parameters('workspaceId')]",
                            "stopOnMultipleConnections": "true"
                        },
                        "protectedSettings": {
                            "workspaceKey": "[listKeys(parameters('workspaceResourceId'), parameters('workspacesApiVersion')).primarySharedKey]",
                            "azureResourceId": "[parameters('vmResourceId')]"
                        }
                    },
                    "dependsOn": [
                        "[concat('Microsoft.Compute/virtualMachines/', parameters('vmName'))]"
                    ]
                }
            ]
        }
    ]
}
'@
#Endregion
            # Create temporary file to store ARM template in
            $TempFile = New-TemporaryFile -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to create temporary file for Linux ARM template" -ErrorAction Stop
            }
            Out-File -InputObject $ArmTemplate -FilePath $TempFile.FullName -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to write arm template for log analytics agent installation to temp file" -ErrorAction Stop
            }
        }
        elseif($NewVM.StorageProfile.OSDisk.OSType -eq "Windows")
        {
            $MMAExentsionName = "MicrosoftMonitoringAgent"
            $MMAOStype = "MicrosoftMonitoringAgent"
            $MMATypeHandlerVersion = "1.0"
#Region Windows ARM template
            # URL of windows template: https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/createMmaWindowsV3.json
            $ArmTemplate = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "vmName": {
            "defaultValue": "",
            "type": "String"
        },
        "vmLocation": {
            "defaultValue": "",
            "type": "String"
        },
        "vmResourceId": {
            "defaultValue": "",
            "type": "String"
        },
        "vmIdentityRequired": {
            "defaultValue": "false",
            "type": "Bool"
        },
        "workspaceName": {
            "defaultValue": "",
            "type": "String"
        },
        "workspaceId": {
            "defaultValue": "",
            "type": "String"
        },
        "workspaceResourceId": {
            "defaultValue": "",
            "type": "String"
        },
        "mmaExtensionName": {
            "defaultValue": "",
            "type": "String"
        },
        "apiVersion": {
            "defaultValue": "2018-10-01",
            "type": "String"
        },
        "workspacesApiVersion": {
            "defaultValue": "2017-04-26-preview",
            "type": "String"
        },
        "OStype": {
            "defaultValue": "",
            "type": "String"
        },
        "typeHandlerVersion": {
            "defaultValue": "",
            "type": "String"
        }
    },
    "variables": {
        "vmIdentity": {
            "type": "SystemAssigned"
        }
    },
    "resources": [
        {
            "type": "Microsoft.Compute/virtualMachines",
            "name": "[parameters('vmName')]",
            "apiVersion": "[parameters('apiVersion')]",
            "location": "[parameters('vmLocation')]",
            "identity": "[if(parameters('vmIdentityRequired'), variables('vmIdentity'), json('null'))]",
            "resources": [
                {
                    "type": "extensions",
                    "name": "[parameters('mmaExtensionName')]",
                    "apiVersion": "[parameters('apiVersion')]",
                    "location": "[parameters('vmLocation')]",
                    "properties": {
                        "publisher": "Microsoft.EnterpriseCloud.Monitoring",
                        "type": "[parameters('OStype')]",
                        "typeHandlerVersion": "[parameters('typeHandlerVersion')]",
                        "autoUpgradeMinorVersion": "true",
                        "settings": {
                            "workspaceId": "[parameters('workspaceId')]",
                            "azureResourceId": "[parameters('vmResourceId')]",
                            "stopOnMultipleConnections": "true"
                        },
                        "protectedSettings": {
                            "workspaceKey": "[listKeys(parameters('workspaceResourceId'), parameters('workspacesApiVersion')).primarySharedKey]"
                        }
                    },
                    "dependsOn": [
                        "[concat('Microsoft.Compute/virtualMachines/', parameters('vmName'))]"
                    ]
                }
            ]
        }
    ]
}
'@
#Endregion
            # Create temporary file to store ARM template in
            $TempFile = New-TemporaryFile -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to create temporary file for Windows ARM template" -ErrorAction Stop
            }
            Out-File -InputObject $ArmTemplate -FilePath $TempFile.FullName -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to write arm template for log analytics agent installation to temp file" -ErrorAction Stop
            }
        }
        else
        {
            Write-Error -Message "Could not determine OS of VM: $($NewVM.Name)"
        }
        $MMADeploymentParams = @{}
        $MMADeploymentParams.Add("vmName", $VMName)
        $MMADeploymentParams.Add("vmLocation", $VMLocation)
        $MMADeploymentParams.Add("vmResourceId", $VMResourceId)
        $MMADeploymentParams.Add("vmIdentityRequired", $VMIdentityRequired)
        $MMADeploymentParams.Add("workspaceName", $WorkspaceName)
        $MMADeploymentParams.Add("workspaceId", $PublicSettings.workspaceId)
        $MMADeploymentParams.Add("workspaceResourceId", $WorkspaceResourceId)
        $MMADeploymentParams.Add("mmaExtensionName", $MMAExentsionName)
        $MMADeploymentParams.Add("apiVersion", $MMAApiVersion)
        $MMADeploymentParams.Add("workspacesApiVersion", $WorkspacesApiVersion)
        $MMADeploymentParams.Add("OStype", $MMAOStype)
        $MMADeploymentParams.Add("typeHandlerVersion", $MMATypeHandlerVersion)

        # Create deployment name
        $DeploymentName = "AutomationControl-PS-" + (Get-Date).ToFileTimeUtc()

        # Deploy solution to new VM
        $ObjectOutPut = New-AzureRmResourceGroupDeployment -ResourceGroupName $VMResourceGroupName -TemplateFile $TempFile.FullName `
            -Name $DeploymentName `
            -TemplateParameterObject $MMADeploymentParams `
            -AzureRmContext $NewVMSubscriptionContext -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Deployment of Log Analytics agent failed" -ErrorAction Stop
        }
        else
        {
            Write-Output -InputObject $ObjectOutPut
            Write-Output -InputObject "VM: $VMName successfully onboarded with Log Analytics MMA agent"
        }

        # Remove temp file with arm template
        Remove-Item -Path $TempFile.FullName -Force
    }
    else
    {
        Write-Warning -Message "The VM: $VMName already has the Log Analytics MMA agent installed."
    }

    # Update scope query if necessary
    $SolutionGroup = $SavedGroups.Value | Where-Object {$_.Id -match "MicrosoftDefaultComputerGroup" -and $_.Properties.Category -eq $SolutionType}

    if ($Null -ne $SolutionGroup)
    {
        if (-not (($SolutionGroup.Properties.Query -match $VMResourceId) -and ($SolutionGroup.Properties.Query -match $VMName)) -and $UpdateScopeQuery)
        {
            # Original saved search query:
            # $DefaultQuery = "Heartbeat | where Computer in~ (`"`") or VMUUID in~ (`"`") | distinct Computer"

            # Make sure to only add VM id into VMUUID block, the same as is done by adding through the portal
            if ($SolutionGroup.Properties.Query -match 'VMUUID')
            {
                # Will leave the "" inside "VMUUID in~ () so can find out what is added by runbook (left of "") and what is added through portal (right of "")
                $NewQuery = $SolutionGroup.Properties.Query.Replace('VMUUID in~ (', "VMUUID in~ (`"$($NewVM.VmId)`",")
            }
#Region Solution Onboarding ARM Template
            # ARM template to deploy log analytics agent extension for both Linux and Windows
            # URL to template: https://wcusonboardingtemplate.blob.core.windows.net/onboardingtemplate/ArmTemplate/createKQLScopeQueryV2.json
            $ArmTemplate = @'
{
    "$schema": "http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "location": {
            "type": "string",
            "defaultValue": ""
        },
        "id": {
            "type": "string",
            "defaultValue": ""
        },
        "resourceName": {
            "type": "string",
            "defaultValue": ""
        },
        "category": {
            "type": "string",
            "defaultValue": ""
        },
        "displayName": {
            "type": "string",
            "defaultValue": ""
        },
        "query": {
            "type": "string",
            "defaultValue": ""
        },
        "functionAlias": {
            "type": "string",
            "defaultValue": ""
        },
        "etag": {
            "type": "string",
            "defaultValue": ""
        },
        "apiVersion": {
            "defaultValue": "2017-04-26-preview",
            "type": "String"
        }
    },
    "resources": [
        {
            "apiVersion": "[parameters('apiVersion')]",
            "type": "Microsoft.OperationalInsights/workspaces/savedSearches",
            "location": "[parameters('location')]",
            "name": "[parameters('resourceName')]",
            "id": "[parameters('id')]",
            "properties": {
                "displayname": "[parameters('displayName')]",
                "category": "[parameters('category')]",
                "query": "[parameters('query')]",
                "functionAlias": "[parameters('functionAlias')]",
                "etag": "[parameters('etag')]",
                "tags": [
                    {
                        "Name": "Group", "Value": "Computer"
                    }
                ]
            }
        }
    ]
}
'@
#Endregion
            # Create temporary file to store ARM template in
            $TempFile = New-TemporaryFile -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to create temporary file for solution ARM template" -ErrorAction Stop
            }
            Out-File -InputObject $ArmTemplate -FilePath $TempFile.FullName -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to write ARM template for solution onboarding to temp file" -ErrorAction Stop
            }
            # Add all of the parameters
            $QueryDeploymentParams = @{}
            $QueryDeploymentParams.Add("location", $WorkspaceInfo.Location)
            $QueryDeploymentParams.Add("id", "/" + $SolutionGroup.Id)
            $QueryDeploymentParams.Add("resourceName", ($WorkspaceInfo.Name + "/" + $SolutionType + "|" + "MicrosoftDefaultComputerGroup").ToLower())
            $QueryDeploymentParams.Add("category", $SolutionType)
            $QueryDeploymentParams.Add("displayName", "MicrosoftDefaultComputerGroup")
            $QueryDeploymentParams.Add("query", $NewQuery)
            $QueryDeploymentParams.Add("functionAlias", $SolutionType + "__MicrosoftDefaultComputerGroup")
            $QueryDeploymentParams.Add("etag", $SolutionGroup.ETag)
            $QueryDeploymentParams.Add("apiVersion", $SolutionApiVersion)

            # Create deployment name
            $DeploymentName = "AutomationControl-PS-" + (Get-Date).ToFileTimeUtc()

            $ObjectOutPut = New-AzureRmResourceGroupDeployment -ResourceGroupName $WorkspaceResourceGroupName -TemplateFile $TempFile.FullName `
                -Name $DeploymentName `
                -TemplateParameterObject $QueryDeploymentParams `
                -AzureRmContext $SubscriptionContext -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                Write-Error -Message "Failed to add VM: $VMName to solution: $SolutionType" -ErrorAction Stop
            }
            else
            {
                Write-Output -InputObject $ObjectOutPut
                Write-Output -InputObject "VM: $VMName successfully added to solution: $SolutionType"
            }

            # Remove temp file with arm template
            Remove-Item -Path $TempFile.FullName -Force
        }
        else
        {
            Write-Warning -Message "The VM: $VMName is already onboarded to solution: $SolutionType"
        }
    }
}
catch
{
    if ($_.Exception.Message)
    {
        Write-Error -Message "$($_.Exception.Message)" -ErrorAction Continue
    }
    else
    {
        Write-Error -Message "$($_.Exception)" -ErrorAction Continue
    }
    throw "$($_.Exception)"
}
finally
{
    Write-Output -InputObject "Runbook: $RunbookName ended at time: $(get-Date -format r)"
}