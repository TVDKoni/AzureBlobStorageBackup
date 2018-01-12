#Requires -Version 2.0

# Parameters
[CmdletBinding()]
Param(
)

# Configuration
# ATTENTION: If you run the script after a configuration change against an already backed up location, the script will delete existing possibly needed backups
$SourceStorageAccountName = "PLEASE SPECIFY" # The source stroage account name
$SourceStorageAccountKey = "PLEASE SPECIFY" # The source stroage account key
$SourceStorageEndpoint = "core.windows.net" # The source stroage endpoint. For Microsoft Azure it is always core.windows.net
$DestinationStorageAccountName = "PLEASE SPECIFY" # The destination stroage account name, does not have to reside in same subscription as source
$DestinationStorageAccountKey = "PLEASE SPECIFY" # The destination stroage account key
$DestinationStorageEndpoint = "core.windows.net" # The source stroage endpoint. For Microsoft Azure it is always core.windows.net
$RetentionDaily = 14 # Keep daily backups of last RetentionDaily days
$RetentionWeekly = 5 # Keep weekly backups of last RetentionWeekly weeks
$RetentionMonthly = 12 # Keep monthly backups of last RetentionMonthly months
$RetentionYearly = 10 # Keep yearly backups of last RetentionYearly years
$RetentionDaySwitch = 0 # The weekday from which we keep weekly, monthly and yearly backups
$RetentionMonthSwitch = 1 # The month from which we keep yearly backups

# Members
$ActualDate = Get-Date
$SourceStorageContext = New-AzureStorageContext -StorageAccountName $SourceStorageAccountName -StorageAccountKey $SourceStorageAccountKey -Endpoint $SourceStorageEndpoint -ErrorAction Stop
$DestinationStorageContext = New-AzureStorageContext -StorageAccountName $DestinationStorageAccountName -StorageAccountKey $DestinationStorageAccountKey -Endpoint $DestinationStorageEndpoint -ErrorAction Stop
$MaxRetentionDaily = $ActualDate.AddDays($RetentionDaily)
$MaxRetentionWeekly = $ActualDate.AddDays($RetentionWeekly * 7)
$MaxRetentionMonthly = $ActualDate.AddMonths($RetentionMonthly)
$MaxRetentionYearly = $ActualDate.AddYears($RetentionYearly)

# Checking configuration
if ($MaxRetentionMonthly -ge $MaxRetentionYearly)
{
    throw "MaxRetentionMonthly should not be larger than MaxRetentionYearly"
}
if ($MaxRetentionWeekly -ge $MaxRetentionMonthly)
{
    throw "MaxRetentionWeekly should not be larger than MaxRetentionMonthly"
}
if ($MaxRetentionDaily -ge $MaxRetentionWeekly)
{
    throw "MaxRetentionDaily should not be larger than MaxRetentionWeekly"
}

# Defining functions
function SyncContainers
{
    Write-Output "Syncing containers"
    #Create missing containers
    $SourceContainers = Get-AzureStorageContainer -Context $SourceStorageContext -ErrorAction Stop
    $DestinationContainers = Get-AzureStorageContainer -Context $DestinationStorageContext -ErrorAction Stop
    $SourceContainers | foreach {
        $SourceContainer = $_
        $DestinationContainer = $DestinationContainers | where { $_.name -eq $SourceContainer.Name }
        if (-not $DestinationContainer) {
            Write-Output " - Creating container '$($SourceContainer.Name)'"
            $tmp = New-AzureStorageContainer -Context $DestinationStorageContext -Name $SourceContainer.Name -ErrorAction SilentlyContinue
        }
    }
    #Check if containers are in sync
    $DestinationContainers = Get-AzureStorageContainer -Context $DestinationStorageContext -ErrorAction Stop
    $SourceContainers | foreach {
        if (-not ($DestinationContainers | where { $_.name -eq $SourceContainer.Name })) {
            throw "Can't create container '$($SourceContainer.Name)' in destination storage account"
        }
    }
    Write-Output " Containers are in sync"
}

function CleanAllInDestination
{
    Write-Output "Cleaning destination storage account"
    $DestinationContainers = Get-AzureStorageContainer -Context $DestinationStorageContext -ErrorAction Stop
    $DestinationContainers | foreach {
        $DestinationContainer = $_
        $DestinationBlobs = Get-AzureStorageBlob -Context $DestinationStorageContext -Container $DestinationContainer.Name -ErrorAction Stop
        $DestinationBlobs | foreach {
            $_.ICloudBlob.Delete()
        }
        Remove-AzureStorageContainer -Context $DestinationStorageContext -Container $DestinationContainer.Name
    }
}

function SyncBlobs
{
    Write-Output "Syncing blobs"
    #Walking though each container
    $SourceContainers = Get-AzureStorageContainer -Context $SourceStorageContext -ErrorAction Stop
    $SourceContainers | foreach {
        $SourceContainer = $_
        Write-Output " Syncing blobs in container '$($SourceContainer.Name)'"
        $SourceBlobs = Get-AzureStorageBlob -Context $SourceStorageContext -Container $SourceContainer.Name -ErrorAction Stop
        #Walking though each blob
        $SourceBlobs | foreach {
            $SourceBlob = $_
            if (-not $SourceBlob.ICloudBlob.SnapshotTime) { #We support only latest blob, no snapshots
                Write-Output "  - Syncing blob '$($SourceBlob.Name)'"
                $DestinationBlob = Get-AzureStorageBlob -Context $DestinationStorageContext -Container $SourceContainer.Name -Blob $SourceBlob.Name -ErrorAction SilentlyContinue
                #Create a snapshot if destination blob already exists
                if ($DestinationBlob) {
				    Write-Output "     Creating Snapshot"
				    $snap = $DestinationBlob.ICloudBlob.CreateSnapshot()
                }
                #Copying the blob
			    Write-Output "     Copying blob"
                $DestinationBlob = Start-AzureStorageBlobCopy -SrcContext $SourceStorageContext -SrcContainer $SourceContainer.Name -SrcBlob $SourceBlob.Name -DestContext $DestinationStorageContext -DestContainer $SourceContainer.Name -DestBlob $SourceBlob.Name -Force -ErrorAction SilentlyContinue
                #Syncing attributes
			    Write-Output "     Syncing Attributes"
                $SourceBlob.ICloudBlob.FetchAttributes()
                $DestinationBlob.ICloudBlob.FetchAttributes()
                $SourceBlob.ICloudBlob.Metadata.Keys | foreach {
                    $DestinationBlob.ICloudBlob.Metadata[$_] = $SourceBlob.ICloudBlob.Metadata[$_]
                }
                $DestinationBlob.ICloudBlob.Metadata["OriginalLastModified"] = $SourceBlob.ICloudBlob.Properties.LastModified.ToString("s")
                for( $attempt = 1; $attempt -le 100; $attempt++ )
                {
                    try
                    {
                        $DestinationBlob.ICloudBlob.SetMetadata()
                        break
                    }
                    catch
                    {
                        sleep -Milliseconds 100
                    }
                }
                #Checking copy
			    Write-Output "     Checking content"
                $DestinationBlob = Get-AzureStorageBlob -Context $DestinationStorageContext -Container $SourceContainer.Name -Blob $SourceBlob.Name -ErrorAction SilentlyContinue
                $DestinationBlob.ICloudBlob.FetchAttributes()
                if ($DestinationBlob.ICloudBlob.Properties["ContentMD5"] -ne $SourceBlob.ICloudBlob.Properties["ContentMD5"])
                {
                    throw "Copied blob does not has same content!"
                }
            }
        }
    }
    Write-Output " Blobs are in sync"
}

function CleanBlobs
{
    Write-Output "Cleaning destination storage account"
    #Walking though all containers
    $DestinationContainers = Get-AzureStorageContainer -Context $DestinationStorageContext -ErrorAction Stop
    $DestinationContainers | foreach {
        $DestinationContainer = $_
        Write-Output " Cleaning container '$($DestinationContainer.Name)'"
        #Walking though all blobs in container
        $DestinationBlobs = Get-AzureStorageBlob -Context $DestinationStorageContext -Container $DestinationContainer.Name -ErrorAction Stop
        $DestinationBlobs | foreach {
            $DestinationBlob = $_
            if ($DestinationBlob.ICloudBlob.SnapshotTime) {
                $SnapTime = $DestinationBlob.ICloudBlob.SnapshotTime
                $SnapTimeDay = $SnapTime.Value.DayOfWeek.value__
                $SnapTimeMonth = $SnapTime.Value.Month
                if ($SnapTime -gt $MaxRetentionDaily)
                {
                    if ($SnapTimeDay -eq $RetentionDaySwitch) # Defines weekly
                    {
                        #TODO Mark as daily
                        if ($SnapTime -gt $MaxRetentionWeekly)
                        {
                            if ($SnapTime.Day -lt 8) # Defines monthly
                            {
                                #TODO Mark as weekly
                                if ($SnapTime -gt $MaxRetentionMonthly)
                                {
                                    if ($SnapTimeMonth -eq $RetentionMonthSwitch) # Defines yearly
                                    {
                                        #TODO Mark as monthly
                                        if ($SnapTime -gt $MaxRetentionYearly)
                                        {
                                            Write-Output "   - Deleting blob '$($DestinationBlob.Name)' in container '$($DestinationContainer.Name)'"
                                            $_.ICloudBlob.Delete()
                                        }
                                    }
                                    else
                                    {
                                        Write-Output "   - Deleting blob '$($DestinationBlob.Name)' in container '$($DestinationContainer.Name)'"
                                        $_.ICloudBlob.Delete()
                                    }
                                }
                            }
                            else
                            {
                                Write-Output "   - Deleting blob '$($DestinationBlob.Name)' in container '$($DestinationContainer.Name)'"
                                $_.ICloudBlob.Delete()
                            }
                        }
                    }
                    else
                    {
                        Write-Output "   - Deleting blob '$($DestinationBlob.Name)' in container '$($DestinationContainer.Name)'"
                        $_.ICloudBlob.Delete()
                    }
                }
            }
        }
    }
    Write-Output " Cleaned"
}

function Report
{
    
}

# Processing the backup
SyncContainers
SyncBlobs
CleanBlobs
Report
