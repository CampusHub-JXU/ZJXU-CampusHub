param(
    [string[]]$FlutterArgs = @("run"),
    [switch]$SkipFlutter
)

$ErrorActionPreference = "Stop"

function Set-ProxyEnv {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Remove-Item "Env:$Name" -ErrorAction SilentlyContinue
        Remove-Item "Env:$($Name.ToLowerInvariant())" -ErrorAction SilentlyContinue
    } else {
        Set-Item "Env:$Name" -Value $Value
        Set-Item "Env:$($Name.ToLowerInvariant())" -Value $Value
    }
}

function Parse-ProxyServer {
    param([string]$ProxyServer)

    $result = @{
        Http  = $null
        Https = $null
        All   = $null
    }

    if ([string]::IsNullOrWhiteSpace($ProxyServer)) {
        return $result
    }

    if ($ProxyServer -notmatch "=") {
        $value = $ProxyServer.Trim()
        if ($value -notmatch "^[a-zA-Z]+://") {
            $value = "http://$value"
        }
        $result.Http = $value
        $result.Https = $value
        $result.All = $value
        return $result
    }

    $pairs = $ProxyServer.Split(";")
    foreach ($pair in $pairs) {
        $parts = $pair.Split("=", 2)
        if ($parts.Count -ne 2) {
            continue
        }

        $scheme = $parts[0].Trim().ToLowerInvariant()
        $value = $parts[1].Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        if ($value -notmatch "^[a-zA-Z]+://") {
            $value = "http://$value"
        }

        switch ($scheme) {
            "http"  { $result.Http = $value }
            "https" { $result.Https = $value }
            "socks" { $result.All = $value }
        }
    }

    if (-not $result.Http) {
        $result.Http = $result.Https
    }
    if (-not $result.Https) {
        $result.Https = $result.Http
    }
    if (-not $result.All) {
        $result.All = $result.Https
    }

    return $result
}

$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$proxyEnable = (Get-ItemProperty -Path $regPath -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
$proxyServer = (Get-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer

if ($proxyEnable -eq 1) {
    $proxy = Parse-ProxyServer -ProxyServer $proxyServer
    Set-ProxyEnv -Name "HTTP_PROXY" -Value $proxy.Http
    Set-ProxyEnv -Name "HTTPS_PROXY" -Value $proxy.Https
    Set-ProxyEnv -Name "ALL_PROXY" -Value $proxy.All

    Write-Host "Using system proxy:"
    Write-Host "HTTP_PROXY=$($env:HTTP_PROXY)"
    Write-Host "HTTPS_PROXY=$($env:HTTPS_PROXY)"
    Write-Host "ALL_PROXY=$($env:ALL_PROXY)"
} else {
    Set-ProxyEnv -Name "HTTP_PROXY" -Value $null
    Set-ProxyEnv -Name "HTTPS_PROXY" -Value $null
    Set-ProxyEnv -Name "ALL_PROXY" -Value $null
    Write-Host "System proxy is OFF. Cleared *_PROXY env vars in current shell."
}

if (-not $SkipFlutter) {
    & flutter @FlutterArgs
    exit $LASTEXITCODE
}
