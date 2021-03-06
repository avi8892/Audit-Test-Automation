﻿#Requires -RunAsAdministrator

<#
BSD 3-Clause License

Copyright (c) 2019, FB Pro GmbH
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#>

using module ATAPHtmlReport
using namespace Microsoft.PowerShell.Commands
using namespace System.Security.AccessControl

# Import setting from file
$Settings = Import-LocalizedData -FileName "Settings.psd1"

#region Import tests configuration settings

$DisaRequirements = Import-LocalizedData -FileName "Win10_DISA_V1R16.psd1"
$CisBenchmarks = Import-LocalizedData -FileName "Win10_CIS_V1.4.0.psd1"
#endregion


#region Logging functions
function New-LogFile {
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
	Param(
		[Parameter(Mandatory = $true)]
		[Alias('LogPath','Path','Logname')]
		[string]
		$LogFilePath
	)

	# Create file if it does not already exists
	if (-not (Test-Path -Path $LogFilePath)) {

		# Create file and start logging
		New-Item -Path $LogFilePath -ItemType File -Force | Out-Null

		$output = @()
		$output += "********************************************************************************"
		$output += " Logfile created at [$([DateTime]::Now)]"
		$output += "********************************************************************************"
		$output += ""
		$output += ""

		$output | Out-File -Append $LogFilePath -Width 80
	}
}
function Write-LogFile {
	param
	(
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[System.Management.Automation.VerboseRecord]
		$Record,

		[Parameter(Mandatory = $false)]
		[string]
		$LogFilePath = $Settings.LogFilePath
	)

	begin {
		New-LogFile -LogFilePath $LogFilePath
	}

	process {
		$output = @()
		$formattedDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
		$levelText = '[WARNING]:'

		$output += "$formattedDate $levelText"
		$output += $Record.Message
		$output += "--------------------------------------------------------------------------------"
		$output += ""

		$output | Out-File -Append $LogFilePath -Width 80
	}
}
#endregion

#region Helper classes
enum AuditResultStatus {
	True
	False
	Warning
	None
}

enum Existence {
	None
	Yes
}

class ConfigMetadata
{
	[string] $Id
	[string] $Task
	$Config

	[ConfigAudit] Test() {
		$testResult = $this.Config.Test()
		return [ConfigAudit]@{
			Id = $this.Id
			Task = $this.Task
			Status = $testResult.Status
			Message = $testResult.Message
		}
	}
}

class DomainRoleConfigMetadata : ConfigMetadata
{
	[string[]] $DomainRole = @()

	[ConfigAudit] Test() {
		if ($this.DomainRole.Count -gt 0) {
			$domainRoles = $this.DomainRole | ForEach-Object { [DomainRole]$_ }
			if ((Get-DomainRole) -notin $domainRoles) {
				return [ConfigAudit]@{
					Id = $this.Id
					Task = $this.Task
					Status = [AuditResultStatus]::None
					Message = 'Not applicable. This audit applies only to {0}.' -f ($this.DomainRole -join ' and ')
				}
			}
		}
		return ([ConfigMetadata]$this).Test()
	}
}

class AuditResult
{
	[AuditResultStatus] $Status
	[string] $Message
}

class ConfigAudit {
	[string] $Id
	[string] $Task
	[AuditResultStatus] $Status
	[string] $Message
}

class ValueRange
{
	[string] $Operation
	$Value

	[bool] Test($value) {
		if (($this.Operation -eq "equals") -or ($this.Operation -eq "not equal")) {
			$negation = $false
			if ($this.Operation -eq "not equal") {
				$negation = $true
			}
			if ($value.Count -ne $this.Value.Count) {
				return $negation
			}
			[array]$tvalue = $value
			[array]$tthisvalue = $this.Value
			for ($i = 0; $i -lt $tthisvalue.Count; $i++) {
				if ($tvalue[$i] -ne $tthisvalue[$i]) {
					return $negation
				}
			}
			return -not ($negation)
		}
		elseif ($this.Operation -eq "greater than") {
			return [int]$value -gt [int]$this.Value
		}
		elseif ($this.Operation -eq "less than") {
			return [int]$value -lt [int]$this.Value
		}
		elseif ($this.Operation -eq "greater than or equal") {
			return [int]$value -ge [int]$this.Value
		}
		elseif ($this.Operation -eq "less than or equal") {
			return [int]$value -le [int]$this.Value
		}
		elseif ($this.Operation -eq "pattern match") {
			return $value -match $this.Value
		}
		else {
			return $False
		}
	}
}

#region Configs
class ComplexConfig
{
	[string] $Operation
	$Configs

	[AuditResult] Test() {
		if ($this.Operation -eq "AND") {
			foreach ($config in $this.Configs) {
				$result = $config.Test()
				if ($result.Status -eq [AuditResultStatus]::False) {
					return $result
				}
			}

			# check for other types
			return [AuditResult]@{
				Status = [AuditResultStatus]::True
				Message = "Compliant"
			}
		}
		elseif ($this.Operation -eq "OR") {
			$messages = @()
			foreach ($config in $this.Configs) {
				$result = $config.Test()
				if ($result.Status -eq [AuditResultStatus]::True) {
					return [AuditResult]@{
						Status = [AuditResultStatus]::True
						Message = "Compliant"
					}
				}

				# check for other types
				$messages += $result.Message
			}
			return [AuditResult]@{
				Status = [AuditResultStatus]::False
				Message = $messages -join "`n"
			}
		}
		return $False
	}
}

class RegistryConfig
{
	[Existence] $Existence
	[string] $Key
	[string] $ValueName
	[ValueRange] $ValueData
	[string] $ValueType

	[AuditResult] Test() {
		try {
			$regValues = Get-ItemProperty -ErrorAction Stop -Path $this.Key -Name $this.ValueName `
				| Select-Object -ExpandProperty $this.ValueName

			if ($this.Existence -eq [Existence]::None) {
				return [AuditResult]@{
					Message = "Registry value found."
					Status = [AuditResultStatus]::False
				}
			}

			if (-not ($this.ValueData.Test($regValues))) {
				$regValue = $regValues -join ", "
				return [AuditResult]@{
					Message = "Registry value is '$regValue'. Expected: $($this.ValueData.Operation) $($this.ValueData.Value)"
					Status = [AuditResultStatus]::False
				}
			}
		}
		catch [System.Management.Automation.PSArgumentException] {
			if ($this.Existence -eq [Existence]::None) {
				return [AuditResult]@{
					Message = "Compliant. Registry value not found."
					Status = [AuditResultStatus]::True
				}
			}

			return [AuditResult]@{
				Message = "Registry value not found."
				Status = [AuditResultStatus]::False
			}
		}
		catch [System.Management.Automation.ItemNotFoundException] {
			if ($this.Existence -eq [Existence]::None) {
				return [AuditResult]@{
					Message = "Compliant. Registry key not found."
					Status = [AuditResultStatus]::True
				}
			}

			return [AuditResult]@{
				Message = "Registry key not found."
				Status = [AuditResultStatus]::False
			}
		}

		return [AuditResult]@{
			Message = "Compliant"
			Status = [AuditResultStatus]::True
		}
	}
}

class UserRightConfig
{
	[string] $UserRight
	[string[]] $Identity

	[AuditResult] Test() {
		$securityPolicy = Get-SecurityPolicy
		$currentUserRights = $securityPolicy["Privilege Rights"][$this.UserRight]

		$identityAccounts = $this.Identity | ConvertTo-NTAccountUser | Where-Object { $null -ne $_ }

		$unexpectedUsers = $currentUserRights.Account | Where-Object { $_ -notin $identityAccounts.Account }
		$missingUsers = $identityAccounts.Account | Where-Object { $_ -notin $currentUserRights.Account }

		if (($unexpectedUsers.Count -gt 0) -or ($missingUsers.Count -gt 0)) {
			$messages = @()
			if ($unexpectedUsers.Count -gt 0) {
				$messages += 'The user right setting contains following unexpected users: ' + ($unexpectedUsers -join ", ")
			}
			if ($missingUsers.Count -gt 0) {
				$messages += 'The user right setting does not contain the following users: ' + ($missingUsers -join ", ")
			}
			$message = $messages -join [System.Environment]::NewLine

			Write-Verbose -Message $message
			return [AuditResult]@{
				Status = [AuditResultStatus]::False
				Message = $message
			}
		}

		return [AuditResult]@{
			Status = [AuditResultStatus]::True
			Message = "Compliant"
		}
	}
}

class AccountPolicyConfig
{
	[string] $Policy
	[ValueRange] $Value

	[AuditResult] Test() {
		$securityPolicy = Get-SecurityPolicy
		$currentAccountPolicy = $securityPolicy["System Access"][$this.Policy]

		if ($null -eq $currentAccountPolicy) {
			return [AuditResult]@{
				Status = [AuditResultStatus]::False
				Message = "Currently not set."
			}
		}

		if (-not $this.Value.Test($currentAccountPolicy)) {
			return [AuditResult]@{
				Status = [AuditResultStatus]::False
				Message = "Currently set to: $currentAccountPolicy. Expected: $($this.Value.Operation) $($this.Value.Value)"
			}
		}

		return [AuditResult]@{
			Status = [AuditResultStatus]::True
			Message = "Compliant"
		}
	}
}

class AuditPolicyConfig
{
	[string] $Subcategory
	[string] $AuditFlag

	[AuditResult] Test() {
		# Get the audit policy for the subcategory $subcategory
		$subCategoryGUID = Get-AuditPolicySubcategoryGUID -Subcategory $this.Subcategory
		$auditPolicyString = auditpol /get /subcategory:"$subCategoryGUID"

		# auditpol does not throw exceptions, so test the results and throw if needed
		if ($LASTEXITCODE -ne 0) {
			$errorString = "'auditpol /get /subcategory:'$subCategoryGUID' returned with exit code $LASTEXITCODE"
			throw [System.ArgumentException] $errorString
			Write-Error -Message $errorString
		}

		if ($null -eq $auditPolicyString) {
			return [AuditResult]@{
				Status   = [AuditResultStatus]::False
				Message = "Couldn't get setting. Auditpol returned nothing."
			}
		}

		# Remove empty lines and headers
		$line = $auditPolicyString `
			| Where-Object { $_ } `
			| Select-Object -Skip 3

		if ($line -notmatch "(No Auditing|Success and Failure|Success|Failure)$") {
			return [AuditResult]@{
				Status   = [AuditResultStatus]::False
				Message = "Couldn't get setting."
			}
		}

		$setting = $Matches[0]

		if ($setting -ne $this.AuditFlag) {
			return [AuditResult]@{
				Status   = [AuditResultStatus]::False
				Message = "Set to: $setting"
			}
		}

		return [AuditResult]@{
			Status   = [AuditResultStatus]::True
			Message = "Compliant"
		}
	}
}

class FirewallProfileConfig
{
	[string] $Profile
	[string] $Setting
	[ValueRange] $Value

	[AuditResult] Test() {
		Write-Verbose -Message "Profile: $($this.Profile), Setting: $($this.Setting), Value: $($this.Value)"

		$firewallProfileArgs = @{ Name = $this.Profile }
		if ($this.Setting -like "AllowLocal*Rules") {
			$this.firewallProfileArgs.PolicyStore = "localhost"
		}

		$profileSettings = Get-NetFirewallProfile @firewallProfileArgs
		$currentValue = $profileSettings | Select-Object -ExpandProperty $this.Setting

		if (-not $this.Value.Test($currentValue)) {
			return [AuditResult]@{
				Status = [AuditResultStatus]::False
				Message = "Profile setting '$this.Setting' is currently set to '$currentValue'. Expected value is '$this.Value'."
			}
		}

		return [AuditResult]@{
			Status = [AuditResultStatus]::True
			Message = "Compliant"
		}
	}
}
#endregion

function Get-DomainRoleConfigMetadata {
	[CmdletBinding()]
	[OutputType([ConfigMetadata])]
	param (
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[hashtable]
		$ConfigMetadata
	)

	process {
		$obj = [DomainRoleConfigMetadata]@{
			Id = $ConfigMetadata.Id
			Task = $ConfigMetadata.Task
			Config = Get-Config -Config $ConfigMetadata.Config
		}
		if ($ConfigMetadata.ContainsKey("DomainRole")) {
			$obj.DomainRole = $ConfigMetadata.DomainRole
		}
		return $obj
	}
}

function Get-ConfigMetadata {
	[CmdletBinding()]
	[OutputType([ConfigMetadata])]
	param (
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[hashtable]
		$ConfigMetadata
	)

	process {
		return [ConfigMetadata]@{
			Id = $ConfigMetadata.Id
			Task = $ConfigMetadata.Task
			Config = Get-Config -Config $ConfigMetadata.Config
		}
	}
}

function Get-Config {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[hashtable]
		$Config
	)

	process {
		# remove side effects on input
		$Config = $Config.Clone()

		if ($Config.Type -eq "ComplexConfig") {
			$Config.Remove("Type")
			$Config.Configs = $Config.Configs | Get-Config
			return New-Object -TypeName "ComplexConfig" -Property $Config
		}
		elseif ($Config.Type -eq "RegistryConfig") {
			$Config.Remove("Type")
			return New-Object -TypeName "RegistryConfig" -Property $Config
		}
		elseif ($Config.Type -eq "UserRightConfig") {
			$Config.Remove("Type")
			return New-Object -TypeName "UserRightConfig" -Property $Config
		}
		elseif ($Config.Type -eq "AccountPolicyConfig") {
			$Config.Remove("Type")
			return New-Object -TypeName "AccountPolicyConfig" -Property $Config
		}
		elseif ($Config.Type -eq "AuditPolicyConfig") {
			$Config.Remove("Type")
			return New-Object -TypeName "AuditPolicyConfig" -Property $Config
		}
		elseif ($Config.Type -eq "FirewallProfileConfig") {
			$Config.Remove("Type")
			return New-Object -TypeName "FirewallProfileConfig" -Property $Config
		}
	}
}
#endregion

#region Helper functions
function PreprocessSpecialValueSetting {
[CmdletBinding()]
Param(
	[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
	[hashtable] $InputObject
)

	Process {
		if ($InputObject.Keys -contains "SpecialValue") {
			$Type = $InputObject.SpecialValue.Type
			$PreValue = $InputObject.SpecialValue.Value

			$InputObject.Remove("SpecialValue")
			if ($Type -eq "Range") {
				$preValue = $preValue.ToLower()

				$predicates = @()
				if ($preValue -match "([0-9]+)[a-z ]* or less") {
					$y = [int]$Matches[1]
					$predicates += { param($x) $x -le $y }.GetNewClosure()
				}
				if ($preValue -match "([0-9]+)[ a-z]* or greater") {
					$y = [int]$Matches[1]
					$predicates += { param($x) $x -ge $y }.GetNewClosure()
				}
				if ($preValue -match "not ([0-9]+)") {
					$y = [int]$Matches[1]
					$predicates += { param($x) $x -ne $y }.GetNewClosure()
				}

				$InputObject.ExpectedValue = $preValue
				$InputObject.Predicate     = {
					param($x)
					return ($predicates | ForEach-Object { &$_ $x }) -notcontains $false
				}.GetNewClosure()
				return $InputObject
			}
			elseif ($Type -eq "Placeholder") {
				$value = $Settings[$preValue]
				$InputObject.Value = $value

				if ([string]::IsNullOrEmpty($value)) {
					$InputObject.ExpectedValue = "Non-empty string."
					$InputObject.Predicate     = { param($x) -not [string]::IsNullOrEmpty($x) }.GetNewClosure()
					return $InputObject
				}

				$InputObject.ExpectedValue = $value
				$InputObject.Predicate     = { param($x) $x -eq $value }.GetNewClosure()
				return $InputObject
			}
		}

		$value = $InputObject.Value

		if ($value.Count -gt 1) {
			$InputObject.ExpectedValue = $value -join ", "
			$InputObject.Predicate     = {
				param([string[]]$xs)

				if ($xs.Count -ne $value.Count) {
					return $false
				}

				$comparisonFunction = [Func[string, string, Boolean]]{ param($a, $b) $a -eq $b }
				$comparison = [System.Linq.Enumerable]::Zip([string[]]$value, $xs, $comparisonFunction)
				return $comparison -notcontains $false
			}.GetNewClosure()
			return $InputObject
		}

		$InputObject.ExpectedValue = $value
		$InputObject.Predicate     = { param([string] $x) $value -eq $x }.GetNewClosure()
		return $InputObject
	}
}

function ConvertTo-NTAccountUser {
	[CmdletBinding()]
	[OutputType([hashtable])]
	Param(
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[string] $Name
	)

	process {
		# Identity doesn't exist on when Hyper-V isn't installed
		if ($Name -eq "NT VIRTUAL MACHINE\Virtual Machines" -and
			(Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Hyper-V").State -ne "Enabled") {
			return $null
		}

		Write-Verbose "[ConvertTo-NTAccountUser] Converting identity '$Name' to NTAccount"
		if ($Name -match "^(S-[0-9-]{3,})") {
			$sidAccount = [System.Security.Principal.SecurityIdentifier]$Name
		}
		else {
			$sidAccount = ([System.Security.Principal.NTAccount]$Name).Translate([System.Security.Principal.SecurityIdentifier])
		}
		return @{
			Account = $sidAccount.Translate([System.Security.Principal.NTAccount])
			Sid =  $sidAccount.Value
		}
	}
}

function Get-SecurityPolicy {
	[CmdletBinding()]
	param ()

	# get a temporary file to save and process the secedit settings
	$securityPolicyPath = Join-Path -Path $env:TEMP -ChildPath 'SecurityPolicy.inf'

	# export the secedit settings to this temporary file
	Write-Verbose "[Get-SecurityPolicy] Exporting local security policies from secedit into tempory file: $securityPolicyPath"
	secedit.exe /export /cfg $securityPolicyPath | Out-Null

	$config = @{}
	switch -regex -file $securityPolicyPath {
		"^\[(.+)\]" { # Section
			$section = $matches[1]
			$config[$section] = @{}
		}
		"(.+?)\s*=(.*)" { # Key
			$name = $matches[1]
			$value = $matches[2] -replace "\*"
			$config[$section][$name] = $value
		}
	}

	Write-Verbose "[Get-SecurityPolicy] Converting identities in 'Privilege Rights' section"
	$privilegeRights = @{}
	foreach ($key in $config["Privilege Rights"].Keys) {
		# Make all accounts SIDs
		$accounts = $($config["Privilege Rights"][$key] -split ",").Trim() | ConvertTo-NTAccountUser -Verbose:$VerbosePreference | Where-Object { $_ -ne $null }
		$privilegeRights[$key] = $accounts
	}
	$config["Privilege Rights"] = $privilegeRights

	# sanitize input
	$systemAccess = @{}
	foreach ($key in $config["System Access"].Keys) {
		$systemAccess[$key] = $config["System Access"][$key].Trim()
	}
	$config["System Access"] = $systemAccess

	return $config
}

# Get domain role
# 0 {"Standalone Workstation"}
# 1 {"Member Workstation"}
# 2 {"Standalone Server"}
# 3 {"Member Server"}
# 4 {"Backup Domain Controller"}
# 5 {"Primary Domain Controller"}
function Get-DomainRole {
	[DomainRole](Get-CimInstance -Class Win32_ComputerSystem).DomainRole
}

function Get-PrimaryDomainSID {
	<#
	.SYNOPSIS
		Obtains SID of the primary AD domain for the local computer
	#>

	[CmdletBinding()]
	Param()
	# Note: this script obtains SID of the primary AD domain for the local computer. It works both
	#       if the local computer is a domain member (DomainRole = 1 or DomainRole = 3)
	#       or if the local computer is a domain controller (DomainRole = 4 or DomainRole = 4).
	#       The code works even under local user account and does not require calling user
	#       to be domain account.

	[string]$domainSID = $null

	[int]$domainRole = Get-DomainRole

	if (($domainRole -ne [DomainRole]::StandaloneWorkstation) -and ($domainRole -ne [DomainRole]::StandaloneServer)) {

		[string] $domain = Get-CimInstance Win32_ComputerSystem | Select-Object -Expand Domain
		[string] $krbtgtSID = (New-Object Security.Principal.NTAccount $domain\krbtgt).Translate([Security.Principal.SecurityIdentifier]).Value
		$domainSID = $krbtgtSID.SubString(0, $krbtgtSID.LastIndexOf('-'))
	}

	return $domainSID
}

function Get-LocalAdminName {
	# The Administrators Group has the SID S-1-5-32-544
	return (Get-LocalGroupMember -SID "S-1-5-32-544").Name `
		| Where-Object { $_.StartsWith($env:COMPUTERNAME) } `
		| ForEach-Object { $_.Substring($env:COMPUTERNAME.Length + 1) }
}

function Get-AuditPolicySubcategoryGUID {
	Param(
		[Parameter(Mandatory = $true)]
		[string] $Subcategory
	)
	switch ($Subcategory) {
		# Information availabe with: auditpol /list /subcategory:* /v
		# System
		'Security State Change'                  { "{0CCE9210-69AE-11D9-BED3-505054503030}" }
		'Security System Extension'              { "{0CCE9211-69AE-11D9-BED3-505054503030}" }
		'System Integrity'                       { "{0CCE9212-69AE-11D9-BED3-505054503030}" }
		'IPsec Driver'                           { "{0CCE9213-69AE-11D9-BED3-505054503030}" }
		'Other System Events'                    { "{0CCE9214-69AE-11D9-BED3-505054503030}" }
		# Logon/Logoff
		'Logon'                                  { "{0CCE9215-69AE-11D9-BED3-505054503030}" }
		'Logoff'                                 { "{0CCE9216-69AE-11D9-BED3-505054503030}" }
		'Account Lockout'                        { "{0CCE9217-69AE-11D9-BED3-505054503030}" }
		'IPsec Main Mode'                        { "{0CCE9218-69AE-11D9-BED3-505054503030}" }
		'IPsec Quick Mode'                       { "{0CCE9219-69AE-11D9-BED3-505054503030}" }
		'IPsec Extended Mode'                    { "{0CCE921A-69AE-11D9-BED3-505054503030}" }
		'Special Logon'                          { "{0CCE921B-69AE-11D9-BED3-505054503030}" }
		'Other Logon/Logoff Events'              { "{0CCE921C-69AE-11D9-BED3-505054503030}" }
		'Network Policy Server'                  { "{0CCE9243-69AE-11D9-BED3-505054503030}" }
		'User / Device Claims'                   { "{0CCE9247-69AE-11D9-BED3-505054503030}" }
		'Group Membership'                       { "{0CCE9249-69AE-11D9-BED3-505054503030}" }
		# Object Access
		'File System'                            { "{0CCE921D-69AE-11D9-BED3-505054503030}" }
		'Registry'                               { "{0CCE921E-69AE-11D9-BED3-505054503030}" }
		'Kernel Object'                          { "{0CCE921F-69AE-11D9-BED3-505054503030}" }
		'SAM'                                    { "{0CCE9220-69AE-11D9-BED3-505054503030}" }
		'Certification Services'                 { "{0CCE9221-69AE-11D9-BED3-505054503030}" }
		'Application Generated'                  { "{0CCE9222-69AE-11D9-BED3-505054503030}" }
		'Handle Manipulation'                    { "{0CCE9223-69AE-11D9-BED3-505054503030}" }
		'File Share'                             { "{0CCE9224-69AE-11D9-BED3-505054503030}" }
		'Filtering Platform Packet Drop'         { "{0CCE9225-69AE-11D9-BED3-505054503030}" }
		'Filtering Platform Connection'          { "{0CCE9226-69AE-11D9-BED3-505054503030}" }
		'Other Object Access Events'             { "{0CCE9227-69AE-11D9-BED3-505054503030}" }
		'Detailed File Share'                    { "{0CCE9244-69AE-11D9-BED3-505054503030}" }
		'Removable Storage'                      { "{0CCE9245-69AE-11D9-BED3-505054503030}" }
		'Central Policy Staging'                 { "{0CCE9246-69AE-11D9-BED3-505054503030}" }
		# Privelege Use
		'Sensitive Privilege Use'                { "{0CCE9228-69AE-11D9-BED3-505054503030}" }
		'Non Sensitive Privilege Use'            { "{0CCE9229-69AE-11D9-BED3-505054503030}" }
		'Other Privilege Use Events'             { "{0CCE922A-69AE-11D9-BED3-505054503030}" }
		# Detailed Tracking
		'Process Creation'                       { "{0CCE922B-69AE-11D9-BED3-505054503030}" }
		'Process Termination'                    { "{0CCE922C-69AE-11D9-BED3-505054503030}" }
		'DPAPI Activity'                         { "{0CCE922D-69AE-11D9-BED3-505054503030}" }
		'RPC Events'                             { "{0CCE922E-69AE-11D9-BED3-505054503030}" }
		'Plug and Play Events'                   { "{0CCE9248-69AE-11D9-BED3-505054503030}" }
		'Token Right Adjusted Events'            { "{0CCE924A-69AE-11D9-BED3-505054503030}" }
		# Policy Change
		'Audit Policy Change'                    { "{0CCE922F-69AE-11D9-BED3-505054503030}" }
		'Authentication Policy Change'           { "{0CCE9230-69AE-11D9-BED3-505054503030}" }
		'Authorization Policy Change'            { "{0CCE9231-69AE-11D9-BED3-505054503030}" }
		'MPSSVC Rule-Level Policy Change'        { "{0CCE9232-69AE-11D9-BED3-505054503030}" }
		'Filtering Platform Policy Change'       { "{0CCE9233-69AE-11D9-BED3-505054503030}" }
		'Other Policy Change Events'             { "{0CCE9234-69AE-11D9-BED3-505054503030}" }
		# Account Management
		'User Account Management'                { "{0CCE9235-69AE-11D9-BED3-505054503030}" }
		'Computer Account Management'            { "{0CCE9236-69AE-11D9-BED3-505054503030}" }
		'Security Group Management'              { "{0CCE9237-69AE-11D9-BED3-505054503030}" }
		'Distribution Group Management'          { "{0CCE9238-69AE-11D9-BED3-505054503030}" }
		'Application Group Management'           { "{0CCE9239-69AE-11D9-BED3-505054503030}" }
		'Other Account Management Events'        { "{0CCE923A-69AE-11D9-BED3-505054503030}" }
		# DS Access
		'Directory Service Access'               { "{0CCE923B-69AE-11D9-BED3-505054503030}" }
		'Directory Service Changes'              { "{0CCE923C-69AE-11D9-BED3-505054503030}" }
		'Directory Service Replication'          { "{0CCE923D-69AE-11D9-BED3-505054503030}" }
		'Detailed Directory Service Replication' { "{0CCE923E-69AE-11D9-BED3-505054503030}" }
		# Account Logon
		'Credential Validation'                  { "{0CCE923F-69AE-11D9-BED3-505054503030}" }
		'Kerberos Service Ticket Operations'     { "{0CCE9240-69AE-11D9-BED3-505054503030}" }
		'Other Account Logon Events'             { "{0CCE9241-69AE-11D9-BED3-505054503030}" }
		'Kerberos Authentication Service'        { "{0CCE9242-69AE-11D9-BED3-505054503030}" }

		Default                                  { "" }
	}
}

function Convert-ToAuditInfo {
	[CmdletBinding()]
	[OutputType([AuditInfo])]
	param (
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[Psobject] $auditObject
	)

	process {
		return [AuditInfo]@{
			Id      = $auditObject.Name
			Task    = $auditObject.Task
			Message = $auditObject.Status
			Audit   = $auditObject.Passed
		}
	}
}
#endregion

#region Audit functions
function Get-RoleAudit {
	[CmdletBinding()]
	[OutputType([AuditInfo])]
	param(
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Id,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Task,

		[Parameter(ValueFromPipelineByPropertyName = $true)]
		[string[]] $Role = @("MemberWorkstation","StandaloneWorkstation")
	)

	process {
		$domainRoles = $Role | ForEach-Object { [DomainRole]$_ }
		if ((Get-DomainRole) -notin $domainRoles) {
			return [AuditInfo]@{
				Id = $Id
				Task = $Task
				Message = "Not applicable. This audit applies to " + ($Role -join " and ") + "."
				Audit = [AuditStatus]::None
			}
		}
		return $null
	}
}

function Get-RegistryAudit {
	[CmdletBinding()]
	[OutputType([AuditInfo])]
	param(
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Id,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Task,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Path,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Name,

		[Parameter(ValueFromPipelineByPropertyName = $true)]
		[AllowEmptyString()]
		[object[]] $Value,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[ScriptBlock] $Predicate,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[String] $ExpectedValue,

		[Parameter(ValueFromPipelineByPropertyName = $true)]
		[bool] $DoesNotExist = $false
	)

	process {
		try {
			$regValues = Get-ItemProperty -ErrorAction Stop -Path $Path -Name $Name `
				| Select-Object -ExpandProperty $Name

			if ($DoesNotExist) {
				return [AuditInfo]@{
					Id = $Id
					Task = $Task
					Message = "Registry value found."
					Audit = [AuditStatus]::False
				}
			}

			if (-not (& $Predicate $regValues)) {
				Write-Verbose "$($Id): Registry value $Name in registry key $Path is not correct."
				$regValue = $regValues -join ", "

				return [AuditInfo]@{
					Id = $Id
					Task = $Task
					Message = "Registry value: $regValue. Differs from expected value: $ExpectedValue."
					Audit = [AuditStatus]::False
				}
			}
		}
		catch [System.Management.Automation.PSArgumentException] {
			Write-Verbose "$($Id): Could not get value $Name in registry key $path."

			if ($DoesNotExist) {
				return [AuditInfo]@{
					Id = $Id
					Task = $Task
					Message = "Compliant. Registry value not found."
					Audit = [AuditStatus]::True
				}
			}

			return [AuditInfo]@{
				Id = $Id
				Task = $Task
				Message = "Registry value not found."
				Audit = [AuditStatus]::False
			}
		}
		catch [System.Management.Automation.ItemNotFoundException] {
			Write-Verbose "$($Id): Could not get key $Name in registry key $path."

			return [AuditInfo]@{
				Id = $Id
				Task = $Task
				Message = "Registry key not found."
				Audit = [AuditStatus]::False
			}
		}

		return [AuditInfo]@{
			Id = $Id
			Task = $Task
			Message = "Compliant"
			Audit = [AuditStatus]::True
		}
	}
}

function Get-UserRightPolicyAudit {
	[CmdletBinding()]
	[OutputType([AuditInfo])]
	Param(
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Id,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Task,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[ValidateSet(
			'SeNetworkLogonRight',
			'SeTcbPrivilege',
			'SeBackupPrivilege',
			'SeChangeNotifyPrivilege',
			'SeSystemtimePrivilege',
			'SeCreatePagefilePrivilege',
			'SeDebugPrivilege',
			'SeRemoteShutdownPrivilege',
			'SeAuditPrivilege',
			'SeIncreaseQuotaPrivilege',
			'SeLoadDriverPrivilege',
			'SeBatchLogonRight',
			'SeServiceLogonRight',
			'SeInteractiveLogonRight',
			'SeSecurityPrivilege',
			'SeSystemEnvironmentPrivilege',
			'SeProfileSingleProcessPrivilege',
			'SeSystemProfilePrivilege',
			'SeAssignPrimaryTokenPrivilege',
			'SeTakeOwnershipPrivilege',
			'SeDenyNetworkLogonRight',
			'SeDenyBatchLogonRight',
			'SeDenyServiceLogonRight',
			'SeDenyInteractiveLogonRight',
			'SeUndockPrivilege',
			'SeManageVolumePrivilege',
			'SeRemoteInteractiveLogonRight',
			'SeDenyRemoteInteractiveLogonRight',
			'SeImpersonatePrivilege',
			'SeCreateGlobalPrivilege',
			'SeIncreaseWorkingSetPrivilege',
			'SeTimeZonePrivilege',
			'SeCreateSymbolicLinkPrivilege',
			'SeDelegateSessionUserImpersonatePrivilege',
			'SeCreateTokenPrivilege',
			'SeCreatePermanentPrivilege',
			'SeIncreaseBasePriorityPrivilege',
			'SeLockMemoryPrivilege',
			'SeRestorePrivilege',
			'SeTrustedCredManAccessPrivilege',
			'SeEnableDelegationPrivilege',
			'SeRelabelPrivilege',
			'SeShutdownPrivilege'
		)]
		[string] $Policy,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[AllowEmptyCollection()]
		[string[]] $Identity
	)

	process {
		$securityPolicy = Get-SecurityPolicy -Verbose:$VerbosePreference
		$currentUserRights = $securityPolicy["Privilege Rights"][$Policy]

		$identityAccounts = $Identity | ConvertTo-NTAccountUser | Where-Object { $_ -ne $null }

		$unexpectedUsers = $currentUserRights.Account | Where-Object { $_ -notin $identityAccounts.Account }
		$missingUsers = $identityAccounts.Account | Where-Object { $_ -notin $currentUserRights.Account }

		if (($unexpectedUsers.Count -gt 0) -or ($missingUsers.Count -gt 0)) {
			$messages = @()
			if ($unexpectedUsers.Count -gt 0) {
				$messages += 'The user right setting contains following unexpected users: ' + ($unexpectedUsers -join ", ")
			}
			if ($missingUsers.Count -gt 0) {
				$messages += 'The user right setting does not contain the following users: ' + ($missingUsers -join ", ")
			}
			$message = $messages -join [System.Environment]::NewLine

			Write-Verbose -Message $message
			return [AuditInfo]@{
				Id = $Id
				Task = $Task
				Message = $message
				Audit = [AuditStatus]::False
			}
		}

		return [AuditInfo]@{
			Id = $Id
			Task = $Task
			Message = "Compliant"
			Audit = [AuditStatus]::True
		}
	}
}

function Get-AuditPolicyAudit {
	[CmdletBinding()]
	[OutputType([AuditInfo])]
	Param(
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Id,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Task,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[ValidateSet(
			'Security System Extension',
			'System Integrity',
			'IPsec Driver',
			'Other System Events',
			'Security State Change',
			'Logon',
			'Logoff',
			'Account Lockout',
			'IPsec Main Mode',
			'IPsec Quick Mode',
			'IPsec Extended Mode',
			'Special Logon',
			'Other Logon/Logoff Events',
			'Network Policy Server',
			'User / Device Claims',
			'Group Membership',
			'File System',
			'Registry',
			'Kernel Object',
			'SAM',
			'Certification Services',
			'Application Generated',
			'Handle Manipulation',
			'File Share',
			'Filtering Platform Packet Drop',
			'Filtering Platform Connection',
			'Other Object Access Events',
			'Detailed File Share',
			'Removable Storage',
			'Central Policy Staging',
			'Non Sensitive Privilege Use',
			'Other Privilege Use Events',
			'Sensitive Privilege Use',
			'Process Creation',
			'Process Termination',
			'DPAPI Activity',
			'RPC Events',
			'Plug and Play Events',
			'Token Right Adjusted Events',
			'Audit Policy Change',
			'Authentication Policy Change',
			'Authorization Policy Change',
			'MPSSVC Rule-Level Policy Change',
			'Filtering Platform Policy Change',
			'Other Policy Change Events',
			'Computer Account Management',
			'Security Group Management',
			'Distribution Group Management',
			'Application Group Management',
			'Other Account Management Events',
			'User Account Management',
			'Directory Service Access',
			'Directory Service Changes',
			'Directory Service Replication',
			'Detailed Directory Service Replication',
			'Kerberos Service Ticket Operations',
			'Other Account Logon Events',
			'Kerberos Authentication Service',
			'Credential Validation')]
		[string] $Subcategory,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[ValidateSet(
			'Success',
			'Failure',
			'Success and Failure',
			'No Auditing')]
		[string] $AuditFlag
	)

	process {
		# Get the audit policy for the subcategory $subcategory
		$subCategoryGUID = Get-AuditPolicySubcategoryGUID -Subcategory $Subcategory
		$auditPolicyString = auditpol /get /subcategory:"$subCategoryGUID"

		# auditpol does not throw exceptions, so test the results and throw if needed
		if ($LASTEXITCODE -ne 0) {
			$errorString = "'auditpol /get /subcategory:'$subCategoryGUID' returned with exit code $LASTEXITCODE"
			throw [System.ArgumentException] $errorString
			Write-Error -Message $errorString
		}

		if ($null -eq $auditPolicyString) {
			return [AuditInfo]@{
				Id      = $Id
				Task    = $Task
				Message = "Couldn't get setting. Auditpol returned nothing."
				Audit   = [AuditStatus]::False
			}
		}

		# Remove empty lines and headers
		$line = $auditPolicyString `
			| Where-Object { $_ } `
			| Select-Object -Skip 3

		if ($line -notmatch "(No Auditing|Success and Failure|Success|Failure)$") {
			return [AuditInfo]@{
				Id      = $Id
				Task    = $Task
				Message = "Couldn't get setting."
				Audit   = [AuditStatus]::False
			}
		}

		$setting = $Matches[0]

		if ($setting -ne $AuditFlag) {
			return [AuditInfo]@{
				Id      = $Id
				Task    = $Task
				Message = "Set to: $setting"
				Audit   = [AuditStatus]::False
			}
		}

		return [AuditInfo]@{
			Id      = $Id
			Task    = $Task
			Message = "Compliant"
			Audit   = [AuditStatus]::True
		}
	}
}

function Get-WindowsOptionalFeatureAudit {
	[CmdletBinding()]
	[OutputType([AuditInfo])]
	Param(
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Id,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Task,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Feature
	)

	process {
		$installState = (Get-WindowsOptionalFeature -Online -FeatureName $Feature).State

		if ($installState -ne "Disabled") {
			return [AuditInfo]@{
				Id = $Id
				Task = $Task
				Message = "The feature is not disabled."
				Audit = [AuditStatus]::False
			}
		}

		return [AuditInfo]@{
			Id = $Id
			Task = $Task
			Message = "Compliant"
			Audit = [AuditStatus]::True
		}
	}
}

enum GARights {
	GENERIC_READ    = 0x80000000
	GENERIC_WRITE   = 0x40000000
	GENERIC_EXECUTE = 0x20000000
	GENERIC_ALL     = 0x10000000
}

# See https://docs.microsoft.com/en-us/windows/desktop/FileIO/file-security-and-access-rights for more information
$GAToFSRMapping = @{
	[GARights]::GENERIC_READ = `
		[FileSystemRights]::ReadAttributes -bor `
		[FileSystemRights]::ReadData -bor `
		[FileSystemRights]::ReadExtendedAttributes -bor `
		[FileSystemRights]::ReadPermissions -bor `
		[FileSystemRights]::Synchronize
	[GARights]::GENERIC_WRITE = `
		[FileSystemRights]::AppendData -bor `
		[FileSystemRights]::WriteAttributes -bor `
		[FileSystemRights]::WriteData -bor `
		[FileSystemRights]::WriteExtendedAttributes -bor `
		[FileSystemRights]::ReadPermissions -bor `
		[FileSystemRights]::Synchronize
	[GARights]::GENERIC_EXECUTE = `
		[FileSystemRights]::ExecuteFile -bor `
		[FileSystemRights]::ReadPermissions -bor `
		[FileSystemRights]::ReadAttributes -bor `
		[FileSystemRights]::Synchronize
	[GARights]::GENERIC_ALL = `
		[FileSystemRights]::FullControl
}

function Convert-FileSystemRight {
	param(
		[Parameter(Mandatory = $true)]
		[FileSystemRights] $OriginalRights
	)

	[FileSystemRights]$MappedRights = [FileSystemRights]::new()

	# map generic access right
	foreach ($GAR in $GAToFSRMapping.Keys) {
		if (($OriginalRights.value__ -band $GAR.value__) -eq $GAR.value__) {
			$MappedRights = $MappedRights -bor $GAToFSRMapping[$GAR]
		}
	}

	# mask standard access rights and object-specific access rights
	$MappedRights = $MappedRights -bor ($OriginalRights -band 0x00FFFFFF)

	return $MappedRights
}

# Non official mappings
$GAToRRMaping = @{
	[GARights]::GENERIC_READ = `
		[RegistryRights]::ReadKey
	[GARights]::GENERIC_WRITE = `
		[RegistryRights]::WriteKey
	[GARights]::GENERIC_ALL = `
		[RegistryRights]::FullControl
}

function Get-FileSystemPermissionsAudit {
	[CmdletBinding()]
	[OutputType([AuditInfo])]
	Param(
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Id,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Task,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Target,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[hashtable] $PrincipalRights
	)

	process {
		if ($Target -match "(%(.+)%)") {
			$varName = $Matches[2]
			$replaceValue = (Get-Item -Path "Env:$varName").Value
			$Target = $Target.Replace($Matches[1], $replaceValue)
		}

		$acls = (Get-Acl $Target).Access

		Write-Verbose "File system permissions for target: $Target)"

		$prinicpalsWithTooManyRights = $acls | Where-Object {
			$_.IdentityReference.Value -NotIn $PrincipalRights.Keys
		}
		$principalsWithWrongRights = $acls `
			| Where-Object { $_.IdentityReference.Value -in $PrincipalRights.Keys } `
			| Where-Object {
				# convert string to rights enum
				$referenceRights = $PrincipalRights[$_.IdentityReference.Value] | ForEach-Object { [FileSystemRights]$_ }
				$mappedRights = Convert-FileSystemRight -OriginalRights $_.FileSystemRights
				$mappedRights -notin $referenceRights
			}

		if (($prinicpalsWithTooManyRights.Count -gt 0) -or ($principalsWithWrongRights.Count -gt 0)) {
			$messages = @()
			$messages += $prinicpalsWithTooManyRights | ForEach-Object {
				$mappedRights = Convert-FileSystemRight -OriginalRights $_.FileSystemRights
				"Unexpected '$($_.IdentityReference)' with access '$($mappedRights)'"
			}
			$messages += $principalsWithWrongRights | ForEach-Object {
				$idKey = $_.IdentityReference.Value
				$mappedRights = Convert-FileSystemRight -OriginalRights $_.FileSystemRights
				"Found '$($idKey)' with access '$($mappedRights)' instead of '$($PrincipalRights[$idKey])'"
			}.GetNewClosure()
			$messages | ForEach-Object { Write-Verbose "$($Id): $_" }

			return [AuditInfo]@{
				Id = $Id
				Task = $Task
				Message = $messages -join "; "
				Audit = [AuditStatus]::False
			}
		}

		return [AuditInfo]@{
			Id = $Id
			Task = $Task
			Message = "Compliant"
			Audit = [AuditStatus]::True
		}
	}
}

function Convert-RegistryRight {
	param(
		[Parameter(Mandatory = $true)]
		[RegistryRights] $OriginalRights
	)

	[RegistryRights]$MappedRights = [RegistryRights]::new()

	# map generic access right
	foreach ($GAR in $GAToRRMaping.Keys) {
		if (($OriginalRights.value__ -band $GAR.value__) -eq $GAR.value__) {
			$MappedRights = $MappedRights -bor $GAToRRMaping[$GAR]
		}
	}

	# mask standard access rights and object-specific access rights
	$MappedRights = $MappedRights -bor ($OriginalRights -band 0x00FFFFFF)

	return $MappedRights
}

function Get-RegistryPermissionsAudit {
	[CmdletBinding()]
	[OutputType([AuditInfo])]
	Param(
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Id,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Task,

        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Target,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[hashtable] $PrincipalRights
	)

	process {
		if ($Target -match "(%(.+)%)") {
			$varName = $Matches[2]
			$replaceValue = (Get-Item -Path "Env:$varName").Value
			$Target = $Target.Replace($Matches[1], $replaceValue)
		}

		$acls = (Get-Acl $Target).Access

		Write-Verbose "Registry permissions for target: $Target)"

		$prinicpalsWithTooManyRights = $acls | Where-Object {
			$_.IdentityReference.Value -NotIn $PrincipalRights.Keys
		}
		$principalsWithWrongRights = $acls `
			| Where-Object { $_.IdentityReference.Value -in $PrincipalRights.Keys } `
			| Where-Object {
				# convert string to rights enum
				$referenceRights = $PrincipalRights[$_.IdentityReference.Value] | ForEach-Object { [RegistryRights]$_ }
				$mappedRights = Convert-RegistryRight -OriginalRights $_.RegistryRights
				$mappedRights -notin $referenceRights
			}

		if (($prinicpalsWithTooManyRights.Count -gt 0) -or ($principalsWithWrongRights.Count -gt 0)) {
			$messages = @()
			$messages += $prinicpalsWithTooManyRights | ForEach-Object {
				$mappedRights = Convert-RegistryRight -OriginalRights $_.RegistryRights
				"Unexpected '$($_.IdentityReference)' with access '$($mappedRights)'"
			}
			$messages += $principalsWithWrongRights | ForEach-Object {
				$idKey = $_.IdentityReference.Value
				$mappedRights = Convert-RegistryRight -OriginalRights $_.RegistryRights
				"Found '$($idKey)' with access '$($mappedRights)' instead of '$($PrincipalRights[$idKey])'"
			}.GetNewClosure()
			$messages | ForEach-Object { Write-Verbose -Message "$($Id): $_" }

			return [AuditInfo]@{
				Id = $Id
				Task = $Task
				Message = $messages -join "; "
				Audit = [AuditStatus]::False
			}
		}

		return [AuditInfo]@{
			Id = $Id
			Task = $Task
			Message = "Compliant"
			Audit = [AuditStatus]::True
		}
	}
}

function Get-FirewallProfileAudit {
	[CmdletBinding()]
	[OutputType([AuditInfo])]
	Param(
		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Id,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Task,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Profile,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Setting,

		[Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
		[string] $Value
	)

	process {
		Write-Verbose -Message "Profile: $Profile, Setting: $Setting, Value: $Value"

		$firewallProfileArgs = @{ Name = $Profile }
		if ($Setting -like "AllowLocal*Rules") {
			$firewallProfileArgs.PolicyStore = "localhost"
		}

		$profileSettings = Get-NetFirewallProfile @firewallProfileArgs
		$currentValue = $profileSettings | Select-Object -ExpandProperty $Setting

		if ($currentValue -ne $Value) {
			return [AuditInfo]@{
				Id = $Id
				Task = $Task
				Message = "Profile setting '$Setting' is currently set to '$currentValue'. Expected value is '$Value'."
				Audit = [AuditStatus]::False
			}
		}

		return [AuditInfo]@{
			Id = $Id
			Task = $Task
			Message = "Compliant"
			Audit = [AuditStatus]::True
		}
	}
}

#endregion


function New-AuditPipeline {
	[CmdletBinding()]
	[OutputType([scriptblock])]
	param(
		[Parameter(Mandatory = $true, Position = 0)]
		[scriptblock[]] $AuditFunctions
	)

	return {
		param(
			[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
			[hashtable] $AuditSetting
		)

		process {
			$auditSettingObj = New-Object -TypeName psobject -Property $AuditSetting

			foreach ($auditFunction in $AuditFunctions) {
				$audit = $auditSettingObj | & $auditFunction -Verbose:$VerbosePreference
				if ($audit -is [AuditInfo]) {
					return $audit
				}
			}
			return $null
		}
	}.GetNewClosure()
}


#region Audits

class BenchmarkSection
{
	[string] $Name
	[ConfigMetadata[]] $Configs
}

class Benchmark
{
	[string] $Name
	[string] $Description
	[BenchmarkSection[]] $Sections

	# Benchmark([hashtable] $benchmark) {
	# 	foreach ($key in $benchmark.Keys) {
	# 		$this.Sections += [BenchmarkSection]@{
	# 			Name = $benchmark[$key].Name
	# 			Configs = $benchmark[$key].Configs
	# 		}
	# 	}
	# }
}

function Get-BenchmarkSectionReport {
	[CmdletBinding()]
	[OutputType([hashtable])]
	param (
		[Parameter(Mandatory = $true)]
		[BenchmarkSection]
		$Section
	)

	$audits = @()
	foreach ($config in $Section.Configs) {
		try {
			$audit = $config.Test()
			$audits += [AuditInfo]@{
				Id      = $config.Id
				Task    = $config.Task
				Message = $audit.Message
				Audit   = $audit.Status
			}
		}
		catch {
			Write-Error @_
			$audits += [AuditInfo]@{
				Id      = $config.Id
				Task    = $config.Task
				Message = "An error occured!"
				Audit   = [AuditStatus]::None
			}
		}
	}
	return @{
		Title = $Section.Name
		AuditInfos = $audits
	}
}

function Get-BenchmarkReport {
	[CmdletBinding()]
	[OutputType([hashtable])]
	param (
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[Benchmark]
		$Benchmark
	)

	$subSections = @()
	foreach	($section in $benchmark.Sections) {
		$subSections += Get-BenchmarkSectionReport -Section $section
	}

	return @{
		Title = $Benchmark.Name
		Description = $Benchmark.Description
		SubSections = $subSections
	}
}
#endregion

class AdapterConfig {
	$Data
	[scriptblock] $Pipeline
	[bool] $ShouldPreprocessSpecialValue

	[AuditResult] Test() {
		$vals = $this.Data
		if ($this.ShouldPreprocessSpecialValue) {
			$vals = $vals | PreprocessSpecialValueSetting
		}
		$ret = $vals | &$this.Pipeline

		return [AuditResult]@{
			Status = [AuditResultStatus]($ret.Audit)
			Message = $ret.Message
		}
	}
}

function Get-AdapterConfigMetadata {
	param(
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[hashtable]
		$Config,

		[Parameter(Mandatory = $true)]
		[scriptblock]
		$Pipeline,

		[switch]
		$ShouldPreprocessSpecialValue = $false
	)

	process {
		return [ConfigMetadata]@{
			Id = $Config.Id
			Task = $Config.Task
			Config = [AdapterConfig]@{
				Data = $Config
				Pipeline = $Pipeline
				ShouldPreprocessSpecialValue = $ShouldPreprocessSpecialValue
			}
		}
	}
}

function Get-CisBenchmark {
	[CmdletBinding()]
	[OutputType([Benchmark])]
	param()

	return [Benchmark]@{
		Name = "CIS Benchmarks"
		Description = "This section contains all benchmarks from CIS Microsoft Windows 10 Enterprise Release 1709 Benchmark v1.4.0."
		Sections = @(
			[BenchmarkSection]@{
				Name = "Registry Settings/Group Policies"
				Configs = $CisBenchmarks.RegistrySettings | Get-ConfigMetadata
			}
			[BenchmarkSection]@{
				Name = "User Rights Assignment"
				Configs = $CisBenchmarks.UserRights | Get-ConfigMetadata
			}
			[BenchmarkSection]@{
				Name = "Account Policies"
				Configs = $CisBenchmarks.AccountPolicies | Get-ConfigMetadata
			}
			[BenchmarkSection]@{
				Name = "Windows Firewall with Advanced Security"
				Configs = $CisBenchmarks.AuditPolicies | Get-ConfigMetadata
			}
			[BenchmarkSection]@{
				Name = "Advanced Audit Policy Configuration"
				Configs = $CisBenchmarks.AuditPolicies | Get-ConfigMetadata
			}
		)
	}
}

function Get-DisaBenchmark {
	[CmdletBinding()]
	[OutputType([Benchmark])]
	param()

	return [Benchmark]@{
		Name = "DISA Recommendations"
		Description = "This section contains all DISA Windows 10 Security Technical Implementation Guide V1R16."
		Sections = @(
			[BenchmarkSection]@{
				Name = "Registry Settings/Group Policies"
				Configs = $DisaRequirements.RegistrySettings `
					| Get-AdapterConfigMetadata `
						-Pipeline (New-AuditPipeline ${Function:Get-RegistryAudit}) `
						-ShouldPreprocessSpecialValue
			}
			[BenchmarkSection]@{
				Name = "User Rights Assignment"
				Configs = $DisaRequirements.UserRights | Get-DomainRoleConfigMetadata
			}
			[BenchmarkSection]@{
				Name = "Account Policies"
				Configs = $DisaRequirements.AccountPolicies | Get-ConfigMetadata
			}
			[BenchmarkSection]@{
				Name = "Windows Features"
				Configs = $DisaRequirements.WindowsOptionalFeatures `
					| Get-AdapterConfigMetadata `
						-Pipeline (New-AuditPipeline ${Function:Get-WindowsOptionalFeatureAudit}) `
						-ShouldPreprocessSpecialValue
			}
			[BenchmarkSection]@{
				Name = "File System Permissions"
				Configs = $DisaRequirements.FileSystemPermissions `
					| Get-AdapterConfigMetadata `
						-Pipeline (New-AuditPipeline ${Function:Get-FileSystemPermissionsAudit}) `
						-ShouldPreprocessSpecialValue
			}
			[BenchmarkSection]@{
				Name = "Registry Permissions"
				Configs = $DisaRequirements.RegistryPermissions `
					| Get-AdapterConfigMetadata `
						-Pipeline (New-AuditPipeline ${Function:Get-RegistryPermissionsAudit}) `
						-ShouldPreprocessSpecialValue
			}
		)
	}
}

#region Report-Generation

function Get-Windows10Report {
	[CmdletBinding()]
	[OutputType([hashtable])]
	param()

	return @{
		Title = "Windows 10 Report"
		ModuleName = "Windows10Audit"
		BasedOn = @(
			"Windows 10 Security Technical Implementation Guide V1R16 2019-01-25"
			"CIS Microsoft Windows 10 Enterprise Release 1709 Benchmark v1.4.0"
		)
		Sections = @(
			(Get-DisaBenchmark | Get-BenchmarkReport)
			(Get-CisBenchmark | Get-BenchmarkReport)
		)
	}
}

function Save-Windows10Report {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]
		$Path,

		[Parameter(Mandatory = $false)]
		[switch]
		$Force,

		[Parameter(Mandatory = $false)]
		[switch]
		$NoClobber
	)

	Get-Windows10Report | Export-Clixml -Path $Path -Force:$Force -NoClobber:$NoClobber
}

<#
	In this section the HTML report gets build and saved to the desired destination set by parameter saveTo
#>
function Save-Windows10HtmlReport {
	[CmdletBinding()]
	param(
		[string] $Path = [Environment]::GetFolderPath("MyDocuments")+"\"+"$(Get-Date -UFormat %Y%m%d_%H%M)_auditreport.html",
		[switch] $DarkMode
	)

	$parent = Split-Path $Path
	if (-not (Test-Path $parent)) {
		Write-Error "The path doesn't not exist!"
	}

	$report = Get-Windows10Report
	Get-ATAPHtmlReport @report -Path $Path -DarkMode:$DarkMode
}

Set-Alias -Name Get-Windows10HtmlReport -Value Save-Windows10HtmlReport
Set-Alias -Name Save-HtmlReport -Value Save-Windows10HtmlReport
Set-Alias -Name Get-HtmlReport -Value Save-Windows10HtmlReport
Set-Alias -Name shr -Value Save-Windows10HtmlReport
#endregion