#Requires -Version 7.0
<#
.SYNOPSIS
Verifie les refus d'ecrasement et la validation des parametres avant tout telechargement.
.DESCRIPTION
Execute l'installateur dans des processus isoles et des dossiers temporaires.
Ne telecharge rien, ne cree aucun raccourci et ne lance aucun serveur.
Le test complet requiert ensuite une installation neuve et deux lancements concurrents.
#>
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'Install-DSH.ps1'
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$fixture = [IO.Directory]::CreateTempSubdirectory('dsh-installer-test-').FullName
try {
    $occupied = Join-Path $fixture 'occupied'
    New-Item -ItemType Directory -Path $occupied | Out-Null
    $marker = Join-Path $occupied 'keep.txt'
    Set-Content -LiteralPath $marker -Value 'preserve-me' -NoNewline
    $cases = @(
        @{ arguments = @('-InstallRoot', $occupied, '-DataHome', (Join-Path $fixture 'data')); expected = 'Dossier deja utilise' },
        @{ arguments = @('-InstallRoot', (Join-Path $fixture 'install'), '-DataHome', $occupied); expected = 'Dossier deja utilise' },
        @{ arguments = @('-InstallRoot', (Join-Path $fixture 'nested'), '-DataHome', (Join-Path $fixture 'nested\data')); expected = 'non imbriques' },
        @{ arguments = @('-InstallRoot', (Join-Path $fixture 'install'), '-DataHome', (Join-Path $fixture 'data'), '-NinferBaseUrl', 'http://user:placeholder@localhost:8000/v1'); expected = 'sans identifiants' },
        @{ arguments = @('-InstallRoot', (Join-Path $fixture 'install'), '-DataHome', (Join-Path $fixture 'data'), '-ModelId', 'example-model'); expected = 'Fournir ensemble' }
    )
    foreach ($case in $cases) {
        $output = & pwsh -NoProfile -File $installer -NoShortcut -NoLaunch @($case.arguments) 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $output -notmatch $case.expected) { throw "Refus attendu : $($case.expected). Sortie : $output" }
        if ([IO.File]::ReadAllText($marker) -ne 'preserve-me') { throw 'Le fichier existant a change.' }
        if ((Test-Path (Join-Path $fixture 'install')) -or (Test-Path (Join-Path $fixture 'data'))) { throw 'Un refus a cree une installation.' }
    }
    Write-Output "$($cases.Count) tests passes ; fichiers existants preserves."
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Nettoyage hors du dossier temporaire refuse.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
