<#
.SYNOPSIS
    Generate SSL certificate for Windows Admin Center

.DESCRIPTION
    Creates a self-signed certificate or requests from domain CA for WAC.
    Supports both self-signed (quick) and CA-issued (production) certificates.

.PARAMETER CertificateType
    Type of certificate to generate: SelfSigned or DomainCA

.PARAMETER Thumbprint
    If provided, exports an existing certificate instead of creating new one

.EXAMPLE
    .\Generate-WACCertificate.ps1 -CertificateType SelfSigned

.EXAMPLE
    .\Generate-WACCertificate.ps1 -CertificateType DomainCA
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("SelfSigned", "DomainCA")]
    [string]$CertificateType = "SelfSigned",
    
    [Parameter(Mandatory=$false)]
    [string]$Thumbprint
)

$ErrorActionPreference = "Stop"

Write-Host "=== WAC SSL Certificate Generator ===" -ForegroundColor Cyan
Write-Host ""

# Get server info
$computerName = $env:COMPUTERNAME
$fqdn = \"$computerName.hybrid.mgmt\"

# Define all DNS names for the certificate
$dnsNames = @(
    $fqdn,
    $computerName,
    \"WAC01.hybrid.mgmt\",
    \"WAC01\",
    \"10.1.0.25\",
    \"localhost\"
)

Write-Host "Certificate will be valid for:" -ForegroundColor Yellow
$dnsNames | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
Write-Host ""

if ($Thumbprint) {
    # Export existing certificate
    Write-Host "Exporting existing certificate: $Thumbprint" -ForegroundColor Yellow
    
    $cert = Get-ChildItem -Path "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction Stop
    
    $exportPath = "$env:TEMP\WAC-Certificate.pfx"
    $password = Read-Host -AsSecureString "Enter password for PFX export"
    
    Export-PfxCertificate -Cert $cert -FilePath $exportPath -Password $password
    
    Write-Host "✓ Certificate exported to: $exportPath" -ForegroundColor Green
    Write-Host "Thumbprint: $Thumbprint" -ForegroundColor Cyan
    exit 0
}

switch ($CertificateType) {
    "SelfSigned" {
        Write-Host "[1/3] Generating self-signed certificate..." -ForegroundColor Yellow
        
        try {
            $certParams = @{
                Subject = "CN=$fqdn"
                DnsName = $dnsNames
                CertStoreLocation = "Cert:\LocalMachine\My"
                KeyExportPolicy = "Exportable"
                KeySpec = "Signature"
                KeyLength = 2048
                KeyAlgorithm = "RSA"
                HashAlgorithm = "SHA256"
                NotAfter = (Get-Date).AddYears(2)
                FriendlyName = "Windows Admin Center SSL Certificate"
            }
            
            $cert = New-SelfSignedCertificate @certParams
            
            Write-Host "✓ Certificate created successfully" -ForegroundColor Green
            Write-Host ""
            Write-Host "Certificate Details:" -ForegroundColor Yellow
            Write-Host "  Thumbprint: $($cert.Thumbprint)" -ForegroundColor Cyan
            Write-Host "  Subject:    $($cert.Subject)" -ForegroundColor Gray
            Write-Host "  Valid From: $($cert.NotBefore)" -ForegroundColor Gray
            Write-Host "  Valid To:   $($cert.NotAfter)" -ForegroundColor Gray
            Write-Host ""
            
            # Export to file for backup/import
            Write-Host "[2/3] Exporting certificate..." -ForegroundColor Yellow
            $exportPath = "$env:TEMP\WAC-Certificate-$($cert.Thumbprint).pfx"
            
            # Prompt for password instead of hardcoding
            Write-Host "Enter PFX export password:" -ForegroundColor Yellow
            $password = Read-Host -AsSecureString
            
            Export-PfxCertificate -Cert $cert -FilePath $exportPath -Password $password | Out-Null
            
            Write-Host "✓ Certificate exported to: $exportPath" -ForegroundColor Green
            Write-Host "  Password: [User Provided]" -ForegroundColor Gray
            Write-Host ""
            
            # Add to Trusted Root (so browsers trust it)
            Write-Host "[3/3] Adding to Trusted Root Certification Authorities..." -ForegroundColor Yellow
            $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store(
                [System.Security.Cryptography.X509Certificates.StoreName]::Root,
                [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
            )
            $rootStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $rootCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certBytes)
            $rootStore.Add($rootCert)
            $rootStore.Close()
            
            Write-Host "✓ Certificate trusted by local machine" -ForegroundColor Green
            Write-Host ""
            
            Write-Host "=== Configuration Complete ===" -ForegroundColor Green
            Write-Host ""
            Write-Host "To use this certificate with WAC, reinstall with:" -ForegroundColor Yellow
            Write-Host "  msiexec /i WindowsAdminCenter.msi /qn SME_PORT=443 SME_THUMBPRINT=$($cert.Thumbprint) SSL_CERTIFICATE_OPTION=installed" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Or install WAC .exe and manually configure the certificate in:" -ForegroundColor Yellow
            Write-Host "  WAC Settings → Gateway → HTTPS certificate" -ForegroundColor Gray
            Write-Host ""
            
        }
        catch {
            Write-Host "✗ Failed to create certificate: $_" -ForegroundColor Red
            exit 1
        }
    }
    
    "DomainCA" {
        Write-Host "[1/2] Requesting certificate from domain CA..." -ForegroundColor Yellow
        
        try {
            # Check if domain CA is available
            $caConfig = certutil -dump | Select-String "Config:"
            if (-not $caConfig) {
                throw "Domain CA not found. Ensure this server is domain-joined and a CA is available."
            }
            
            Write-Host "Using CA configuration: $caConfig" -ForegroundColor Gray
            
            # Create INF file for certificate request
            $infPath = "$env:TEMP\wac-cert-request.inf"
            $infContent = @"
[Version]
Signature="`$Windows NT`$"

[NewRequest]
Subject = "CN=$fqdn"
KeySpec = 1
KeyLength = 2048
Exportable = TRUE
MachineKeySet = TRUE
SMIME = FALSE
PrivateKeyArchive = FALSE
UserProtected = FALSE
UseExistingKeySet = FALSE
ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
ProviderType = 12
RequestType = PKCS10
KeyUsage = 0xa0

[Extensions]
2.5.29.17 = "{text}"
$(($dnsNames | ForEach-Object { "_continue_ = `"dns=$_&`"" }) -join "`n")

[RequestAttributes]
CertificateTemplate = WebServer
"@
            
            $infContent | Out-File -FilePath $infPath -Encoding ascii
            
            # Generate certificate request
            $requestPath = "$env:TEMP\wac-cert-request.req"
            certreq -new $infPath $requestPath | Out-Null
            
            # Submit to CA and retrieve certificate
            $certPath = "$env:TEMP\wac-cert.cer"
            certreq -submit -config $caConfig $requestPath $certPath
            
            # Accept and install certificate
            certreq -accept $certPath
            
            # Find the newly installed certificate
            $cert = Get-ChildItem -Path "Cert:\LocalMachine\My" | 
                Where-Object { $_.Subject -eq "CN=$fqdn" } | 
                Sort-Object NotBefore -Descending | 
                Select-Object -First 1
            
            if ($cert) {
                Write-Host "✓ Certificate issued and installed" -ForegroundColor Green
                Write-Host ""
                Write-Host "Certificate Details:" -ForegroundColor Yellow
                Write-Host "  Thumbprint: $($cert.Thumbprint)" -ForegroundColor Cyan
                Write-Host "  Subject:    $($cert.Subject)" -ForegroundColor Gray
                Write-Host "  Issuer:     $($cert.Issuer)" -ForegroundColor Gray
                Write-Host "  Valid From: $($cert.NotBefore)" -ForegroundColor Gray
                Write-Host "  Valid To:   $($cert.NotAfter)" -ForegroundColor Gray
                Write-Host ""
                
                # Export
                Write-Host "[2/2] Exporting certificate..." -ForegroundColor Yellow
                $exportPath = "$env:TEMP\WAC-Certificate-$($cert.Thumbprint).pfx"
                
                # Prompt for password instead of hardcoding
                Write-Host "Enter PFX export password:" -ForegroundColor Yellow
                $password = Read-Host -AsSecureString
                
                Export-PfxCertificate -Cert $cert -FilePath $exportPath -Password $password | Out-Null
                
                Write-Host "✓ Certificate exported to: $exportPath" -ForegroundColor Green
                Write-Host "  Password: WACCert2025!" -ForegroundColor Gray
                Write-Host ""
                
                Write-Host "=== Configuration Complete ===" -ForegroundColor Green
                Write-Host ""
                Write-Host "To use this certificate with WAC, reinstall with:" -ForegroundColor Yellow
                Write-Host "  msiexec /i WindowsAdminCenter.msi /qn SME_PORT=443 SME_THUMBPRINT=$($cert.Thumbprint) SSL_CERTIFICATE_OPTION=installed" -ForegroundColor Cyan
                Write-Host ""
            }
            else {
                throw "Certificate was not found in certificate store after installation"
            }
            
            # Cleanup
            Remove-Item $infPath, $requestPath, $certPath -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host "✗ Failed to request certificate from CA: $_" -ForegroundColor Red
            Write-Host ""
            Write-Host "Troubleshooting:" -ForegroundColor Yellow
            Write-Host "  - Ensure this server is domain-joined" -ForegroundColor Gray
            Write-Host "  - Verify a Certificate Authority is available in the domain" -ForegroundColor Gray
            Write-Host "  - Check that WebServer template is published and accessible" -ForegroundColor Gray
            Write-Host "  - Run: certutil -dump to verify CA configuration" -ForegroundColor Gray
            exit 1
        }
    }
}
