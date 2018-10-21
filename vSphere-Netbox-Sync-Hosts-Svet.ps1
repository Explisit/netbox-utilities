#Requires -Version 5
<#
.SYNOPSIS
    Synchronize Netbox Virtual Machines from VMware vCenter.

.DESCRIPTION
    The Sync-Netbox cmdlet uses the Django Swagger REST API included in Netbox and VMware PowerCLI to synchronize data
    from vCenter to Netbox.
    Function skeleton adapted from https://gist.github.com/9to5IT/9620683

.PARAMETER Token
    Netbox REST API token

.NOTES
    Version:        1.1
    Author:         Joe Wegner <joe at jwegner dot io>
    Creation Date:  2018-02-08
    Purpose/Change: Initial script development
    License:        GPLv3
	
.VERSION_CONTROL

	Version:		1.2
	Author:			Svet
	Creation Date:  2018-02-08
	Purpose/Change: Adding Hosts to Netbox - prerequisite is that device types and clusters must be already in Netbox. Custom Objects are required 
	datastore info, network info and HW version

    Note that this script relies heavily on the PersistentID field in vCenter, as that will uniquely identify the VM
    You will need to create a vcenter_persistent_id custom field on your VM object in Netbox for this to work properly

    removed PowerCLI requires header due to loading error
    #Requires -Version 5 -Modules VMware.PowerCLI
	
	Custom_Object						Description
	host_boot_time						Boot Time
	host_connected_datastores			Connected Datastores
	host_connected_networks				Connected Networks
	host_connected_nics					Connected NICS
	host_cpu_number						CPU Number
	host_memory_capacity				Memory
	host_processor_type					Processor Type
	host_vmkernel_port_ip				VMkernel Management IP
	host_vmotion_port_ip				vMotion IP Address
	host_vmware_build					VMware Build
	host_vmware_version					VMware Version
	
#>

#---------------------------------------------------------[Initialisations]--------------------------------------------------------

#Set Error Action to Silently Continue
#$ErrorActionPreference = "SilentlyContinue"
# allow verbose messages to be recorded in transcript
$VerbosePreference = "Continue"

#----------------------------------------------------------[Declarations]----------------------------------------------------------

# store common paths in variables for URI creation
# update for your Netbox instance
$URIBase = "http://192.168.1.114/api"
$ClustersPath = "/virtualization/clusters"
$VirtualMachinesPath = "/virtualization/virtual-machines"
$PlatformsPath = "/dcim/platforms"
$InterfacesPath = "/virtualization/interfaces"
$IPAddressesPath = "/ipam/ip-addresses"
$DevicesPath = "/dcim/devices"
$DevicesTypePath = "/dcim/device-types"

# Disconnect from all vCenter Servers
disconnect-viserver * -confirm:$false

#-----------------------------------------------------------[Functions]------------------------------------------------------------

function Sync-Netbox-Hosts {
    param (
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [String]
        $Token
    )
    
    begin {
        # setup headers for Netbox API calls
        $TokenHeader = "Token " + $Token
        $Headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $Headers.Add("Accept", "application/json")
        $Headers.Add("Authorization", $TokenHeader)
        
        # first, we will clear out any VMs that are in Netbox but no longer in vCenter
        
        # get all Hosts in vCenter
        $Hosts = Get-VMhost
        $HostsCount = "Retrieved $HostsCount.count from vCenter"
        Write-Verbose $HostsCount
   
        
        # retrieve all Hosts from Netbox
        $URI = $URIBase + $DevicesPath + "/?limit=0"
        $Response = Invoke-RESTMethod -Method GET -Headers $Headers -ContentType "application/json" -URI $URI
        ConvertTo-JSON $Response | Write-Verbose
        
			
        # check each Netbox Host against list from vCenter and delete if not present
        #foreach ($VM in $Response.Results) {
        #    $PersistentID = $VM.custom_fields.vcenter_persistent_id
        #    if ($vCenterPersistentIDs -notcontains $PersistentID) {
        #        # Delete old VM from Netbox inventory
        #        $NetboxID = $VM.ID
        #        $URI = $URIBase + $VirtualMachinesPath + "/" + $NetboxID + "/"
        #        $Response = Invoke-RESTMethod -Method DELETE -Headers $Headers -ContentType "application/json" -URI $URI
        #        #ConvertTo-JSON $Response | Write-Verbose
        #        $Message = "Deleting " + $VM.Name
        #        Write-Verbose $Message
        #    }
        #}

        
		# Create mapping of vCenter OSFullName to Netbox platform IDs
        #$NetboxPlatforms = @{}
        #$URI = $URIBase + $PlatformsPath + "/?limit=0"
        #$Response = Invoke-RESTMethod -Method GET -Headers $Headers -ContentType "application/json" -URI $URI
        #ConvertTo-JSON $Response | Write-Verbose
       # 
       # foreach ($Platform in $Response.Results) {
       #     $NetboxPlatforms[$Platform.Name] = $Platform.ID
       # }
        
        # Create mapping of vCenter Cluster Names to Netbox cluster IDs
        $NetboxClusters = @{}
        $URI = $URIBase + $ClustersPath + "/?limit=0"
        $Response = Invoke-RESTMethod -Method GET -Headers $Headers -ContentType "application/json" -URI $URI
        ConvertTo-JSON $Response | Write-Verbose
        
        foreach ($Cluster in $Response.Results) {
            $NetboxClusters[$Cluster.Name] = $Cluster.ID
        }
        
        # retrieve all clusters from vCenter
        $Clusters = Get-Cluster
        
        # iterate through the clusters
        foreach ($Cluster in $Clusters) {
            # Retrive Netbox ID for cluster
            $ClusterID = $NetboxClusters[$Cluster.Name]
        
            # Retrieve all VMs in cluster
            $VMhosts = Get-VMhost -Location $Cluster
        
            # Iterate through each VM object
            foreach ($VMhost in $VMhosts) {
                ## Query Netbox for Hosts using VMhost Name  from vCenter
                $URI = $URIBase + $DevicesPath + "/?name=" + $VMhosts.Name
                $Response = Invoke-RESTMethod -Method GET -Headers $Headers -ContentType "application/json" -URI $URI
                ConvertTo-JSON $Response | Write-Verbose
        
                # A successful request will always have a results dictionary, though it may be empty
                $NetboxInfo = $Response.Results
				
				# Retrieve Netbox ID for Host if available
				$NetboxID = $NetboxInfo.ID
                               
                # Create object to hold this VM's attributes for export
                $vCenterInfo = @{}
            
                # calculate values for comparison
				# Get Host CPU Number
                $vCPUs = $VMhost.NumCPU
				# Get HostMemory 
                $HostMemory = $VMhost.MemoryTotalGB
        
                # Match up VMHost with proper Netbox Cluster
                #$VMHost = Get-VMHost | Select-Object -Property Name
				if ($NetboxInfo.Cluster) {
                    if ($NetboxInfo.Cluster.ID -ne $ClusterID) { $vCenterInfo["cluster"] = $ClusterID }
                } else {
                    $vCenterInfo["cluster"] = $ClusterID
                }
        
                #if ($NetboxInfo.vCPUs -ne $vCPUs) { $vCenterInfo["vcpus"] = $vCPUs }
                
				# Set ESXi Host CPU Number
				$vCenterInfo["custom_fields"] += @{"host_cpu_number" = $vCPUs}
				
				# Set ESXi Host Memory
				$vCenterInfo["custom_fields"] += @{"host_memory_capacity" = $HostMemory}
				
				# Set ESXi Host Major Version
				$vCenterInfo["custom_fields"] += @{"host_vmware_version" = $VMhost.Version}
								
				# Set ESXi Host Build Number
				$vCenterInfo["custom_fields"] += @{"host_vmware_build" = $VMhost.Build}
                
				# Set Netbox Name to Host Name
                $Name = $VMhost.Name.ToLower()
                $vCenterInfo["name"] = $Name
				 
				# Set Processor Type
				$vCenterInfo["custom_fields"] += @{"host_processor_type" = $VMhost.ProcessorType}
				
				# Set Manufacturer
				$vCenterInfo["manufacturer"] = $VMhost.ExtensionData.Hardware.Systeminfo.Vendor
								
				# Set vMotion IP
				$vmotion_ip = Get-Vmhost -Name $Name | Get-VMHostNetworkAdapter -VMKernel |  ? VMotionEnabled -eq $True | select IP,SubNetMask,PortGroupName,DeviceName 
				$vCenterInfo["custom_fields"] += @{"host_vmotion_port_ip" = $vmotion_ip}
				
				# Set VMKernel IP
				$vmkernel_ip = Get-Vmhost -Name $Name | Get-VMHostNetworkAdapter -VMKernel | ? VMotionEnabled -eq $False | select IP,SubNetMask,PortGroupName,DeviceName 
				$vCenterInfo["custom_fields"] += @{"host_vmkernel_port_ip" = $vmkernel_ip}
				
				# Set Model
				$host_model = $VMhost.ExtensionData.Hardware.Systeminfo.Model
				$vCenterInfo["model_name"] = $VMhost.ExtensionData.Hardware.Systeminfo.Model
				
				# Set Device Type
				$URI_Device = $URIBase + $DevicesTypePath + "/?model=" + $host_model
                $Response = Invoke-RESTMethod -Method GET -Headers $Headers -ContentType "application/json" -URI $URI_Device
				ConvertTo-JSON $Response | Write-Verbose
				
                $NetboxInfo_type = $Response.Results
				
				# Retrieve Netbox ID for Host if available
				$NetboxInfo_typeID = $NetboxInfo_type.ID
				$vCenterInfo["device_type"] = $NetboxInfo_typeID
				
				# Set ESXi Host Boot Time
				$vCenterInfo["custom_fields"] += @{"host_boot_time" = $VMhost.ExtensionData.Runtime.Boottime.ToString()}
								
				# Set Site Name
				$vCenterInfo["site"] = "1"
				
				# Set Device_Role to Server - ID 8
				$vCenterInfo["device_role"] = "8"
				
				# Set Connection State
				if ($VMhost.ConnectionState -eq "Connected") {
                    # Netbox status ID 1 = Active
                    if ($NetboxInfo.Status) {
                        if ($NetboxInfo.Status.Label -ne "Active") { $vCenterInfo["status"] = 1 }
                    } else {
                        $vCenterInfo["status"] = 1
                    }
                } else {
                    # Host is not connected on
                    # Netbox status ID 0 = Offline
                    if ($NetboxInfo.Status) {
                        if ($NetboxInfo.Status.Label -eq "Active") { $vCenterInfo["status"] = 0 }
                    } else {
                        $vCenterInfo["status"] = 0
                    }
                }
				
			 $vCenterInfo
			 
			 
			 if ($vCenterInfo.Count -gt 0) {
                # Create JSON of data for POST/PATCH
                $vCenterJSON = ConvertTo-JSON $vCenterInfo
				
				if ($NetboxID) {
                        # VM already exists in Netbox, so update with any new info
                        Write-Verbose "Updating Netbox VM:"
                        Write-Verbose $vCenterJSON
                        $URI = $URIBase + $DevicesPath + "/"
                        $Response = Invoke-RESTMethod -Method PATCH -Headers $Headers -ContentType "application/json" -Body $vCenterJSON -URI $URI
                        ConvertTo-JSON $Response | Write-Verbose
                      }
				
				else {
					Write-Verbose "Creating new VM in Netbox:"
                    Write-Verbose $vCenterJSON
                    # VM does not exist in Netbox, so create new VM entry
                    $URI = $URIBase + $DevicesPath + "/"
                    $Response = Invoke-RESTMethod -Method POST -Headers $Headers -ContentType "application/json" -Body $vCenterJSON -URI $URI
                    ConvertTo-JSON $Response | Write-Verbose
					}
				} else {
                    $VMhost = $NetboxInfo.Name
                    Write-Verbose "VM $VMhost already exists in Netbox and no changes needed"
                }
						 
	        }
        }
    }
    
    process {
    }
    
    end {
    }
}


#-----------------------------------------------------------[Execution]------------------------------------------------------------

# setup logging to file
$Date = Get-Date -UFormat "%Y-%m-%d_%H-%m-%S"
$LogPath = "E:\Powercli\Logs" + $Date + "_vcenter_netbox_host_sync.log"
Start-Transcript -Path $LogPath


# import the PowerCLI module
Import-Module VMware.PowerCLI

# Make sure that you are connected to the vCenter servers before running this manually
$Credential = Get-Credential

# Connect to the specified vCenter server/s
Connect-VIServer -Server vCenter_server/s  -Credential $Credential



# If running as a scheduled task, ideally you can use a service account
# that can login to both Windows and vCenter with the account's Kerberos ticket
# In that case, you can remove the -Credential from the above Connect-VIServer call

# create your own token at your Netbox instance, e.g. https://netbox.example.com/user/api-tokens/
# You may need to assign addtional user permissions at https://netbox.example.com/admin/auth/user/
# since API permissions are not inherited from LDAP group permissions
$Token = "YOU-API-KEY"
Sync-Netbox-Hosts -Token $Token
# If you want to see REST responses, add the Verbose flag
#Sync-Netbox -Verbose -Token $Token
Stop-Transcript

# Disconnect from all vCenter Servers
disconnect-viserver * -confirm:$false
