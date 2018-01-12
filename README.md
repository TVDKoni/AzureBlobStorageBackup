# Azure Blob Storage Backup
With this PowerShell script you are able to backup a blob storage to another one. File versions are handled with snapshots in the destination blob.

## Installation
Installation is not more than downloading the PowerShell script [BackupStorage.ps1](https://raw.githubusercontent.com/TVDKoni/AzureBlobStorageBackup/master/BackupStorage.ps1) and configuring it to your needs

## Prerequisites
* Two existing Azure blob storages

## Usage
Start a PowerShell session and run the script BackupStorage.ps1.

## Known issues
* Snapshots in the source storage are not backed up
* If you run the script after a configuration change against an already backed up location, the script will delete existing possibly needed backups


