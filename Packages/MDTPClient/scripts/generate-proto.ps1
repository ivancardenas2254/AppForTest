[CmdletBinding()]
param(
    [string]$ProtocPath = $env:PROTOC,
    [string]$ProtocGenSwiftPath = $env:PROTOC_GEN_SWIFT,
    [switch]$Check
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$protoDirectory = Join-Path $root "proto"
$protoFile = Join-Path $protoDirectory "protocol_v1_completo.proto"
$outputDirectory = Join-Path $root "Sources\MDTPClient"
$outputFile = Join-Path $outputDirectory "protocol_v1_completo.pb.swift"

function Resolve-Protoc {
    if ($ProtocPath) {
        if (-not (Test-Path -LiteralPath $ProtocPath)) {
            throw "No existe el protoc indicado: $ProtocPath"
        }
        return (Resolve-Path -LiteralPath $ProtocPath).Path
    }

    $local = Join-Path $root ".tools\protoc\bin\protoc.exe"
    if (Test-Path -LiteralPath $local) {
        return $local
    }

    $command = Get-Command protoc -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw @"
No se encontro 'protoc'.

Opciones:
  1. Ejecutar: .\scripts\setup-tools.ps1
  2. Instalar protoc y agregarlo al PATH.
  3. Pasar -ProtocPath "C:\ruta\a\protoc.exe".
"@
}

function Resolve-ProtocGenSwift {
    if ($ProtocGenSwiftPath) {
        if (-not (Test-Path -LiteralPath $ProtocGenSwiftPath)) {
            throw "No existe el protoc-gen-swift indicado: $ProtocGenSwiftPath"
        }
        return (Resolve-Path -LiteralPath $ProtocGenSwiftPath).Path
    }

    $local = Join-Path $root ".tools\bin\protoc-gen-swift.exe"
    if (Test-Path -LiteralPath $local) {
        return $local
    }

    $command = Get-Command protoc-gen-swift -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
        throw "No se encontro 'swift' ni 'protoc-gen-swift'. Ejecuta .\scripts\setup-tools.ps1."
    }

    $checkout = Join-Path $root ".build\checkouts\swift-protobuf"
    if (-not (Test-Path -LiteralPath $checkout)) {
        Write-Host "Resolviendo SwiftProtobuf..."
        & swift package resolve --package-path $root
        if ($LASTEXITCODE -ne 0) {
            throw "Fallo 'swift package resolve'."
        }
    }

    if (-not (Test-Path -LiteralPath $checkout)) {
        throw "No se encontro SwiftProtobuf en $checkout. Ejecuta .\scripts\setup-tools.ps1."
    }

    $built = Join-Path $checkout ".build\release\protoc-gen-swift.exe"
    if (-not (Test-Path -LiteralPath $built)) {
        Write-Host "Compilando protoc-gen-swift..."
        & swift build --package-path $checkout -c release --product protoc-gen-swift
        if ($LASTEXITCODE -ne 0) {
            throw "Fallo la compilacion de protoc-gen-swift."
        }
    }

    if (-not (Test-Path -LiteralPath $built)) {
        throw "No se genero protoc-gen-swift. Ejecuta .\scripts\setup-tools.ps1."
    }
    return $built
}

if (-not (Test-Path -LiteralPath $protoFile)) {
    throw "No existe el contrato: $protoFile"
}

$protoc = Resolve-Protoc
$plugin = Resolve-ProtocGenSwift
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("mdtp-proto-" + [Guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Force -Path $temporaryDirectory | Out-Null

try {
    $arguments = @(
        "--plugin=protoc-gen-swift=$plugin",
        "--swift_opt=Visibility=Public",
        "--swift_out=$temporaryDirectory",
        "--proto_path=$protoDirectory",
        $protoFile
    )

    Write-Host "Generando modelos Swift desde $protoFile"
    & $protoc @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "protoc fallo con codigo $LASTEXITCODE."
    }

    $generated = Join-Path $temporaryDirectory "protocol_v1_completo.pb.swift"
    if (-not (Test-Path -LiteralPath $generated)) {
        throw "protoc no genero el archivo esperado: $generated"
    }

    if (-not (Test-Path -LiteralPath $outputFile)) {
        if ($Check) {
            Write-Error "El archivo generado no existe: $outputFile"
            exit 1
        }
        Copy-Item -LiteralPath $generated -Destination $outputFile
        Write-Host "Creado $outputFile"
        exit 0
    }

    $expectedHash = (Get-FileHash -LiteralPath $generated -Algorithm SHA256).Hash
    $currentHash = (Get-FileHash -LiteralPath $outputFile -Algorithm SHA256).Hash

    if ($expectedHash -eq $currentHash) {
        Write-Host "OK: los modelos Swift estan actualizados."
        exit 0
    }

    if ($Check) {
        Write-Host "El archivo generado esta desactualizado respecto de $protoFile."
        $differences = Compare-Object (Get-Content -LiteralPath $generated) (Get-Content -LiteralPath $outputFile)
        if ($differences) {
            Write-Host "Primeras diferencias (< generado, > actual):"
            $differences | Select-Object -First 20 | Format-Table -AutoSize | Out-String | Write-Host
        }
        exit 1
    }

    Copy-Item -LiteralPath $generated -Destination $outputFile -Force
    Write-Host "Actualizado $outputFile"
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
