[CmdletBinding()]
param(
    [string]$Version = "27.3",
    [string]$ProtocZip,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$toolsDirectory = Join-Path $root ".tools"
$protocDirectory = Join-Path $toolsDirectory "protoc"
$protocExecutable = Join-Path $protocDirectory "bin\protoc.exe"
$pluginBinDirectory = Join-Path $toolsDirectory "bin"
$pluginExecutable = Join-Path $pluginBinDirectory "protoc-gen-swift.exe"

$expectedHashes = @{
    "27.3" = "BDCCD341A0C25FF4F65D8530F170C78CE5681E42920AA5D892F27AC06CC3BBA0"
}

if (-not $expectedHashes.ContainsKey($Version)) {
    throw "Version de protoc no fijada: $Version. Agrega su SHA-256 en scripts/setup-tools.ps1."
}

function Assert-Swift {
    if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
        throw "No se encontro 'swift' en PATH. Instala el toolchain de Swift 6.4 o superior."
    }
}

New-Item -ItemType Directory -Force -Path $toolsDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $pluginBinDirectory | Out-Null

if ((-not (Test-Path -LiteralPath $protocExecutable)) -or $Force) {
    if (-not $ProtocZip) {
        $ProtocZip = Join-Path ([System.IO.Path]::GetTempPath()) "protoc-$Version-win64.zip"
        if ((-not (Test-Path -LiteralPath $ProtocZip)) -or $Force) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $url = "https://github.com/protocolbuffers/protobuf/releases/download/v$Version/protoc-$Version-win64.zip"
            Write-Host "Descargando protoc $Version desde $url"
            Invoke-WebRequest -Uri $url -OutFile $ProtocZip -UseBasicParsing
        }
    }

    $actualHash = (Get-FileHash -LiteralPath $ProtocZip -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHashes[$Version]) {
        throw "SHA-256 incorrecto para $ProtocZip. Esperado $($expectedHashes[$Version]), obtenido $actualHash."
    }

    if (Test-Path -LiteralPath $protocDirectory) {
        Remove-Item -LiteralPath $protocDirectory -Recurse -Force
    }
    Write-Host "Extrayendo protoc en $protocDirectory"
    Expand-Archive -LiteralPath $ProtocZip -DestinationPath $protocDirectory -Force
}

if (-not (Test-Path -LiteralPath $protocExecutable)) {
    throw "No se encontro protoc en $protocExecutable despues de la instalacion."
}

if ((-not (Test-Path -LiteralPath $pluginExecutable)) -or $Force) {
    Assert-Swift

    Write-Host "Resolviendo SwiftProtobuf..."
    & swift package resolve --package-path $root
    if ($LASTEXITCODE -ne 0) {
        throw "Fallo 'swift package resolve'."
    }

    $checkout = Join-Path $root ".build\checkouts\swift-protobuf"
    if (-not (Test-Path -LiteralPath $checkout)) {
        throw "No se encontro el checkout de SwiftProtobuf en $checkout."
    }

    Write-Host "Compilando protoc-gen-swift..."
    & swift build --package-path $checkout -c release --product protoc-gen-swift
    if ($LASTEXITCODE -ne 0) {
        throw "Fallo la compilacion de protoc-gen-swift."
    }

    $builtPlugin = Join-Path $checkout ".build\release\protoc-gen-swift.exe"
    if (-not (Test-Path -LiteralPath $builtPlugin)) {
        throw "No se genero el ejecutable en $builtPlugin."
    }

    Copy-Item -LiteralPath $builtPlugin -Destination $pluginExecutable -Force
}

$protocVersion = (& $protocExecutable --version).Trim()
$pluginVersion = (& $pluginExecutable --version).Trim()

Write-Host ""
Write-Host "Herramientas listas:"
Write-Host "  $protocVersion"
Write-Host "  $pluginVersion"
Write-Host "  protoc:            $protocExecutable"
Write-Host "  protoc-gen-swift:  $pluginExecutable"
