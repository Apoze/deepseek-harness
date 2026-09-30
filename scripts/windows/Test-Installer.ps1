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
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
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
    # Execute the installer's actual configuration statements without downloads or plugin commands.
    $source = [IO.File]::ReadAllText($installer)
    $assignments = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    $start = ($assignments | Where-Object { $_.Left.Extent.Text -eq '$ninferRows' } | Select-Object -First 1).Extent.StartOffset
    $end = ($assignments | Where-Object { $_.Left.Extent.Text -eq '$cli' -and $_.Extent.StartOffset -gt $start } | Select-Object -First 1).Extent.StartOffset
    $initialize = [scriptblock]::Create($source.Substring($start, $end - $start))
    $profileLoop = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Variable.Extent.Text -eq '$profile' }, $true) | Select-Object -First 1
    $pluginLoop = $profileLoop.Body.Statements | Where-Object { $_ -is [System.Management.Automation.Language.ForEachStatementAst] } | Select-Object -First 1
    $bodyStart = $profileLoop.Body.Extent.StartOffset + 1
    $writeProfile = [scriptblock]::Create($source.Substring($bodyStart, $pluginLoop.Extent.StartOffset - $bodyStart))
    foreach ($configured in @($false, $true)) {
        $DataHome = Join-Path $fixture "profile-settings-$configured"
        New-Item -ItemType Directory -Path $DataHome | Out-Null
        $NinferBaseUrl = $(if ($configured) { 'http://localhost:8000/v1' } else { '' })
        $ModelId = $(if ($configured) { 'fixture-model' } else { '' })
        $ContextWindow = 131072
        $SearxngUrl = ''
        . $initialize
        $globalRows = Get-Content -Raw -LiteralPath (Join-Path $DataHome 'cordis.patch.yml') | ConvertFrom-Json
        if (@($globalRows | Where-Object id -eq 'llm-ninfer').Count) { throw 'NInfer must not override native settings through the home patch.' }
        foreach ($profile in @('web', 'sdk', 'headless')) {
            . $writeProfile
            $written = Get-Content -Raw -LiteralPath (Join-Path $profileDir 'cordis.patch.yml') | ConvertFrom-Json
            $ninfer = @($written | Where-Object id -eq 'llm-ninfer')
            if ($ninfer.Count -ne 1 -or $ninfer[0].disabled -ne (-not $configured)) { throw 'Expected exactly one editable profile NInfer entry.' }
            if ($configured -and $ninfer[0].config.models[0].id -ne $ModelId) { throw 'Model setting lost.' }
        }
    }
    Write-Output 'Configuration NInfer par profil validee avec et sans connexion initiale.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Nettoyage hors du dossier temporaire refuse.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
