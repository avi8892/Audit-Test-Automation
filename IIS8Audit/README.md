# CIS IIS 8 Audit Script
_based on CIS Microsoft IIS 8 Benchmarks v1.5.0 12-30-2016_

## Overview

The `IIS8Audit`-Module benchmarks the current systems settings with current hardening standards such as the CIS Microsoft IIS Benchmarks. This module is specifically designed for Windows Server 2012 with IIS 8.

## Requirements

Please make sure that following requirements are fulfilled:

* **PowerShell 5.1:** To find out the current version use `$PSVersionTable.PSVersion`.
* **ATAPHtmlReport Module:** This module is used for the html report generation and is [included](../ATAPHtmlReport) in the Audit Test Automation Package. Follow the instructions at the link to install the module.
* **IISAdministration Module:** The audit module uses Cmdlets from the IISAdministration module which is *not* included in a IIS 8 installation. Please download the module first and put it into the Windows PowerShell folder.

If you have a internet connection on your machine you can simply open an elevated PowerShell and type (to install the module)

```Powershell
Install-Module -Name IISAdministration,ATAPHtmlReport
```

## Installation

The easiest way to get the module is by installing it with `Install-Module -Name IIS8Audit`. This also installs all the dependencies of this module.

### Loading the IIS Audit module

You only need to import the module when you haven't installed it. When loading the module, make sure that the manifest is loaded as well. Do not include the file extension of the module.

```Powershell
Import-Module -Name .\IIS8Audit -Verbose
```

This is important because the manifest tells Powershell about the assemblies and modules that the module requires.

## Troubleshooting

If you get an error like:
```
Get-IISSite : Method not found: 'System.String System.String.Format(System.IFormatProvider, System.String,
System.Object)'.
```

Try the following in the given order:
1. install the latest Windows Updates
2. install a newer .NET Framework

## Sample report

You can find a sample report in the [Sample](Sample) folder.
