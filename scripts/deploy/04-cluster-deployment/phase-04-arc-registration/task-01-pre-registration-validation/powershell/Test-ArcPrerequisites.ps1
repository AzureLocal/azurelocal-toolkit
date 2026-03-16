# Task 01 - Pre-Registration Environment Validation (run on each node)

Install-Module -Name AzStackHci.EnvironmentChecker -Repository PSGallery -Force -AllowClobber
Import-Module AzStackHci.EnvironmentChecker

Invoke-AzStackHciConnectivityValidation -Verbose | Format-Table Name, Status, Description -AutoSize
