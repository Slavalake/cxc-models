param(
    [string]$Owner = "Slavalake",
    [string]$Repository = "cxc-models",
    [string]$Tag = "models-v1",
    [string]$ModelDirectory = (Join-Path $PSScriptRoot "..\..\x64\Release\models"),
    [switch]$Publish
)

$ErrorActionPreference = "Stop"

function Get-GitHubCredential {
    $credentialInput = "protocol=https`nhost=github.com`nusername=$Owner`n`n"
    $credentialLines = $credentialInput | git credential fill
    $credential = @{}

    foreach ($line in $credentialLines) {
        $parts = $line -split "=", 2
        if ($parts.Count -eq 2) {
            $credential[$parts[0]] = $parts[1]
        }
    }

    if (-not $credential.password) {
        throw "GitHub authentication was not returned by Git Credential Manager."
    }

    return $credential
}

function Get-ReleaseByTag {
    param(
        [hashtable]$Headers,
        [string]$ApiBase
    )

    try {
        return Invoke-RestMethod `
            -Uri "$ApiBase/releases/tags/$Tag" `
            -Headers $Headers `
            -Method Get
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            return $null
        }
        throw
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot "manifest.json"
$checksumsPath = Join-Path $repoRoot "SHA256SUMS.txt"
$resolvedModelDirectory = (Resolve-Path -LiteralPath $ModelDirectory).Path

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "manifest.json was not found at $manifestPath"
}
if (-not (Test-Path -LiteralPath $checksumsPath)) {
    throw "SHA256SUMS.txt was not found at $checksumsPath"
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$modelAssets = foreach ($model in $manifest.models) {
    $path = Join-Path $resolvedModelDirectory $model.asset
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Model asset is missing: $path"
    }

    $item = Get-Item -LiteralPath $path
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($item.Length -ne [int64]$model.bytes -or $actualHash -ne $model.sha256) {
        throw "Model verification failed: $($model.asset)"
    }

    $item
}

$credential = Get-GitHubCredential
try {
    $headers = @{
        Authorization = "Bearer $($credential.password)"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent" = "CXC-Model-Publisher"
    }
    $apiBase = "https://api.github.com/repos/$Owner/$Repository"
    $release = Get-ReleaseByTag -Headers $headers -ApiBase $apiBase

    if (-not $release) {
        $releaseBody = @{
            tag_name = $Tag
            target_commitish = "main"
            name = "CXC Models v1"
            body = "Versioned CXC model assets. Files are validated against manifest.json and SHA256SUMS.txt."
            draft = $true
            prerelease = $false
        } | ConvertTo-Json

        $release = Invoke-RestMethod `
            -Uri "$apiBase/releases" `
            -Headers $headers `
            -Method Post `
            -ContentType "application/json" `
            -Body $releaseBody
        Write-Output "Created draft release $Tag."
    }

    $assetsToUpload = @(
        Get-Item -LiteralPath $manifestPath
        Get-Item -LiteralPath $checksumsPath
        $modelAssets
    )

    foreach ($asset in $assetsToUpload) {
        $assetHash = (Get-FileHash -LiteralPath $asset.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedDigest = "sha256:$assetHash"
        $existingAsset = @($release.assets) |
            Where-Object { $_.name -eq $asset.Name } |
            Select-Object -First 1

        if ($existingAsset -and
            $existingAsset.size -eq $asset.Length -and
            $existingAsset.digest -eq $expectedDigest) {
            Write-Output "Verified existing asset: $($asset.Name)"
            continue
        }

        if ($existingAsset) {
            Invoke-RestMethod `
                -Uri "$apiBase/releases/assets/$($existingAsset.id)" `
                -Headers $headers `
                -Method Delete | Out-Null
            Write-Output "Removed outdated asset: $($asset.Name)"
        }

        $encodedName = [Uri]::EscapeDataString($asset.Name)
        $uploadUri = "https://uploads.github.com/repos/$Owner/$Repository/releases/$($release.id)/assets?name=$encodedName"
        Invoke-RestMethod `
            -Uri $uploadUri `
            -Headers $headers `
            -Method Post `
            -ContentType "application/octet-stream" `
            -InFile $asset.FullName | Out-Null
        Write-Output "Uploaded asset: $($asset.Name)"

        $release = Invoke-RestMethod `
            -Uri "$apiBase/releases/$($release.id)" `
            -Headers $headers `
            -Method Get
    }

    if ($Publish -and $release.draft) {
        $release = Invoke-RestMethod `
            -Uri "$apiBase/releases/$($release.id)" `
            -Headers $headers `
            -Method Patch `
            -ContentType "application/json" `
            -Body '{"draft":false}'
        Write-Output "Published release $Tag."
    }

    $release = Invoke-RestMethod `
        -Uri "$apiBase/releases/$($release.id)" `
        -Headers $headers `
        -Method Get

    [pscustomobject]@{
        Repository = "$Owner/$Repository"
        Tag = $release.tag_name
        Draft = $release.draft
        Assets = @($release.assets).Count
        ReleaseUrl = $release.html_url
    }
}
finally {
    $credential.Clear()
    Remove-Variable credential -ErrorAction SilentlyContinue
}
