<#
    .SYNOPSIS
        Installs the OMS Agent to Azure VMs with the Guest Agent

    .DESCRIPTION
        Traverses an entire subscription / resource group/ or list of VMs to
        install and configure the Log Analytics extension. If no ResourceGroupNames
        or VMNames are provided, all VMs will have the extension installed.
        Otherwise a superset of the 2 parameters is used to determine VM list.

    .PARAMETER azureSubscriptionID
        ID of Azure subscription to use

    .PARAMETER azureEnvironment
        The Azure Cloud environment to use, i.e. AzureCloud, AzureUSGovernment

    .PARAMETER LogAnalyticsWorkspaceName
        Log Analytic workspace name

    .PARAMETER LAResourceGroup
        Resource Group of Log Analytics workspace

    .PARAMETER ResourceGroupNames
        List of Resource Groups. VMs within these RGs will have the extension installed
        Should be specified in format ['rg1','rg2']

    .PARAMETER VMNames
        List of VMs to install OMS extension to
        Specified in the format ['vmname1','vmname2']

    .NOTES
        Version:        1.0
        Author:         Chris Wallen
        Creation Date:  09/10/2019
#>
Param
(
    [parameter(mandatory)]
    [string]
    $azureSubscriptionID,

    [parameter(mandatory)]
    [string]
    $azureEnvironment,

    [parameter(mandatory)]
    [string]
    $WorkspaceName,

    [parameter(mandatory)]
    [string]
    $LAResourceGroup,

    [string[]]
    $ResourceGroupNames,

    [string[]]
    $VMNames
)

$connectionName = "AzureRunAsConnection"

# Get the connection "AzureRunAsConnection "
$servicePrincipalConnection = Get-AutomationConnection -Name $connectionName -ErrorAction Stop

"Logging in to Azure..."
Add-AzureRmAccount `
    -ServicePrincipal `
    -TenantId $servicePrincipalConnection.TenantId `
    -ApplicationId $servicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint `
    -EnvironmentName $azureEnvironment `
    -ErrorAction Stop

$azContext = Select-AzureRmSubscription -subscriptionId $azureSubscriptionID -ErrorAction Stop

$vms = @()

if (-not $ResourceGroupNames -and -not $VMNames)
{
    Write-Output "No resource groups or VMs specified. Collecting all VMs"
    $vms = Get-AzureRMVM
}
elseif ($ResourceGroupNames -and -not $VMNames)
{
    foreach ($rg in $ResourceGroupNames)
    {
        Write-Output "Collecting VM facts from resource group $rg"
        $vms += Get-AzureRmVM -ResourceGroupName $rg
    }
}
else
{
    foreach ($VMName in $VMNames)
    {
        $azureResource = Get-AzureRmResource -Name $VMName -ResourceType 'Microsoft.Compute/virtualMachines'

        if ($azureResource.Count -lt 1)
        {
            Write-Error -Message "Failed to find $VMName"
        }
        elseif ($azureResource.Count -gt 1)
        {
            Write-Error -Message "Found multiple VMs with the name $VMName. Unable to configure extension"
        }

        $vms += Get-AzureRMVM -Name $VMName -ResourceGroupName $azureResource.ResourceGroupName
    }
}

$workspace = Get-AzureRmOperationalInsightsWorkspace -Name $WorkspaceName -ResourceGroupName $LAResourceGroup -ErrorAction Stop
$key = (Get-AzureRmOperationalInsightsWorkspaceSharedKeys -ResourceGroupName $LAResourceGroup -Name $WorkspaceName).PrimarySharedKey

$PublicSettings = @{"workspaceId" = $workspace.CustomerId }
$ProtectedSettings = @{"workspaceKey" = $key }

#Loop through each VM in the array and deploy the extension
foreach ($vm in $vms)
{    
    Start-Job -ArgumentList $azContext, $vm, $workspace, $key, $PublicSettings, $ProtectedSettings -ScriptBlock {
        
        Param 
        (
            $azContext,
            $vm,
            $workspace,
            $key,
            $PublicSettings,
            $ProtectedSettings
        )

        $vmStatus = (Get-AzureRmVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status).Statuses.DisplayStatus[-1]

        Write-Output "Processing VM: $($vm.Name)"

        if ($vmStatus -ne 'VM running')
        {
            Write-Warning -Message "Skipping VM as it is not currently powered on"
        }

        #Check to see if Linux or Windows
        if ($vm.OsProfile.LinuxConfiguration -eq $null)
        {
            $extensions = Get-AzureRmVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -Name 'Microsoft.EnterpriseCloud.Monitoring' -ErrorAction SilentlyContinue            
            #Make sure the extension is not already installed before attempting to install it
            if (-not $extensions)
            {
                Write-Output "Adding MicrosoftMonitoringAgent extension to VM: $($vm.Name)"
                $result = Set-AzureRmVMExtension -ExtensionName "Microsoft.EnterpriseCloud.Monitoring" `
                    -ResourceGroupName $vm.ResourceGroupName `
                    -VMName $vm.Name `
                    -Publisher "Microsoft.EnterpriseCloud.Monitoring" `
                    -ExtensionType "MicrosoftMonitoringAgent" `
                    -TypeHandlerVersion 1.0 `
                    -Settings $PublicSettings `
                    -ProtectedSettings $ProtectedSettings `
                    -Location $vm.Location
            }
            else
            {
                Write-Output "Skipping VM - Extension already installed"
            }
        }
        else
        {
            $extensions = Get-AzureRmVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -Name 'OmsAgentForLinux' -ErrorAction SilentlyContinue

            #Make sure the extension is not already installed before attempting to install it
            if (-not $extensions)
            {
                Write-Output "Adding OmsAgentForLinux extension to VM: $($vm.Name)"
                $result = Set-AzureRmVMExtension -ExtensionName "OmsAgentForLinux" `
                    -ResourceGroupName $vm.ResourceGroupName `
                    -VMName $vm.Name `
                    -Publisher "Microsoft.EnterpriseCloud.Monitoring" `
                    -ExtensionType "OmsAgentForLinux" `
                    -TypeHandlerVersion 1.0 `
                    -Settings $PublicSettings `
                    -ProtectedSettings $ProtectedSettings `
                    -Location $vm.Location
            }
            else
            {
                Write-Output "Skipping VM - Extension already installed"
            }
        }
    }  
}
$runningJobs = Get-Job -State Running
While ($runningJobs.Count -gt 0)
{
    foreach ($job in $runningJobs)
    {
        Receive-Job $job.Id
    }
    $runningJobs = Get-Job -State Running
}
