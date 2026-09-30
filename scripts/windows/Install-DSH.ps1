#Requires -Version 7.0
<#
.SYNOPSIS
Installe la fork publique Apoze et ses sept plugins sur un nouveau PC Windows, sans Git ni gh.
.DESCRIPTION
Necessite Node.js 24 ou superieur, PowerShell 7 et Internet. Installe pnpm 11.7.0
dans le dossier de l'application, telecharge les archives publiques, compile,
enregistre les bundles natifs et cree un raccourci a serveur unique.
La branche DSH par defaut est integration/dsh-0.2.0-rc.1-native. Les plugins
viennent de main ; chaque reference est resolue en commit avant telechargement.
Les versions attendues sont verifiees ; les commits et SHA256 sont consignes.
Installation neuve uniquement : refuse les dossiers d'installation ou de donnees
non vides et un raccourci existant. Aucune suppression automatique en cas d'echec.
Ne contient ni cle API, ni adresse de serveur personnel, ni modele personnel.
NInfer reste desactive jusqu'a sa configuration. Les autres plugins sont actifs.
Configurer ensuite NInfer et la reference NINFER_API_KEY dans les reglages DSH.
SearXNG utilise localhost:8080 par defaut ; changer son endpoint dans les reglages.
Ne copie aucune conversation, connexion MCP ou donnee d'une autre installation.
.EXAMPLE
pwsh -NoProfile -File .\Install-DSH.ps1 -FullAccess
.EXAMPLE
pwsh -NoProfile -File .\Install-DSH.ps1 -NinferBaseUrl http://localhost:8000/v1 -ModelId your-model-id -ContextWindow 131072 -SearxngUrl http://localhost:8080 -FullAccess
.EXAMPLE
Get-Help .\Install-DSH.ps1 -Full
.PARAMETER CoreRef
Branche, tag ou commit de Apoze/deepseek-harness. Ne change pas le depot source.
.PARAMETER FullAccess
Lance DSH en danger-full-access. Sans ce parametre, conserve le mode par defaut de DSH.
.PARAMETER NinferBaseUrl
URL optionnelle, sans identifiants, de votre serveur NInfer compatible. Exige ModelId et ContextWindow.
.PARAMETER NoShortcut
Ne cree pas de raccourci. Le lanceur reste disponible dans InstallRoot.
.PARAMETER NoLaunch
Ne lance pas le navigateur apres l'installation.
.PARAMETER GitHubToken
Jeton optionnel pour les depots prives, fourni comme SecureString avec Read-Host -AsSecureString.
Utilise en memoire pour les telechargements, jamais enregistre dans l'installation.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
    [string]$DataHome = (Join-Path $env:USERPROFILE '.dsh'),
    [string]$CoreRef = 'integration/dsh-0.2.0-rc.1-native',
    [ValidateRange(1024, 65535)][int]$Port = 3080,
    [string]$NinferBaseUrl,
    [string]$ModelId,
    [ValidateRange(1, 2147483647)][int]$ContextWindow,
    [string]$SearxngUrl,
    [Security.SecureString]$GitHubToken,
    [switch]$FullAccess,
    [switch]$NoShortcut,
    [switch]$NoLaunch
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
if (-not $IsWindows) { throw 'Cet installateur cible Windows.' }

function Invoke-Checked([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command a echoue (code $LASTEXITCODE)." }
}
function Assert-EmptyDirectory([string]$Path) {
    if ((Test-Path -LiteralPath $Path) -and
        ((-not (Test-Path -LiteralPath $Path -PathType Container)) -or
         @(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0)) {
        throw "Dossier deja utilise : $Path. Installation neuve uniquement ; vos fichiers sont conserves."
    }
}
function Assert-Endpoint([string]$Value) {
    if (-not $Value) { return }
    $uri = [uri]$Value
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http', 'https') -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'Utiliser une URL HTTP(S) sans identifiants, parametres ni fragment.'
    }
}
function Get-SourceRevision([string]$Repository, [string]$Ref) {
    $encodedRef = [uri]::EscapeDataString($Ref)
    try {
        $metadata = Invoke-RestMethod -Uri "https://api.github.com/repos/Apoze/$Repository/commits/$encodedRef" -Headers $downloadHeaders
    } catch {
        throw "Impossible de lire Apoze/$Repository ($Ref). Verifier le reseau, la limite GitHub et la visibilite du depot. Pour un depot prive, fournir -GitHubToken (Read-Host 'Jeton GitHub' -AsSecureString)."
    }
    if ($metadata.sha -notmatch '^[0-9a-f]{40}$') { throw 'Commit GitHub invalide.' }
    return [ordered]@{ repository = "Apoze/$Repository"; ref = $Ref; commit = $metadata.sha }
}
function Get-SourceArchive([string]$Repository, [string]$Destination) {
    $record = $revisions[$Repository]
    $zip = Join-Path $downloads "$Repository.zip"
    $archiveUrl = if ($GitHubToken) { "https://api.github.com/repos/Apoze/$Repository/zipball/$($record.commit)" }
                  else { "https://codeload.github.com/Apoze/$Repository/zip/$($record.commit)" }
    try { Invoke-WebRequest -Uri $archiveUrl -Headers $downloadHeaders -OutFile $zip }
    catch { throw "Telechargement de Apoze/$Repository impossible. Aucun fichier existant n'a ete supprime." }
    $unpack = Join-Path $downloads $Repository
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $unpack)
    $children = @(Get-ChildItem -LiteralPath $unpack -Directory)
    if ($children.Count -ne 1) { throw "Archive inattendue : $Repository" }
    $source = [IO.Path]::GetFullPath($children[0].FullName)
    $target = [IO.Path]::GetFullPath($Destination)
    if (-not $source.StartsWith($downloads + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not $target.StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Deplacement hors du dossier installation refuse.'
    }
    Move-Item -LiteralPath $source -Destination $target
    $record.archiveSha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    return $record
}

$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$DataHome = [IO.Path]::GetFullPath($DataHome).TrimEnd('\')
if ($InstallRoot -eq $DataHome -or
    $InstallRoot.StartsWith($DataHome + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $DataHome.StartsWith($InstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'InstallRoot et DataHome doivent etre deux dossiers distincts, non imbriques.'
}
Assert-EmptyDirectory $InstallRoot
Assert-EmptyDirectory $DataHome
Assert-Endpoint $NinferBaseUrl
Assert-Endpoint $SearxngUrl
if (($NinferBaseUrl -or $ModelId -or $ContextWindow) -and -not ($NinferBaseUrl -and $ModelId -and $ContextWindow)) {
    throw 'Fournir ensemble NinferBaseUrl, ModelId et ContextWindow, ou aucun des trois.'
}
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'DeepSeek Harness.lnk'
if (-not $NoShortcut -and (Test-Path -LiteralPath $shortcutPath)) { throw 'Le raccourci existe deja. Utiliser -NoShortcut pour une installation separee.' }
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { throw "Le port $Port est deja utilise." }
$node = (Get-Command node.exe -ErrorAction Stop).Source
$npm = (Get-Command npm.cmd -ErrorAction Stop).Source
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$nodeMajor = [int]((& $node --version).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 24) { throw 'Installer Node.js 24 ou superieur, puis rouvrir PowerShell.' }

$pluginVersions = [ordered]@{
    'dsh-file-mentions' = '1.1.1'
    'dsh-safe-download-files' = '0.2.0'
    'dsh-llm-ninfer' = '0.2.2'
    'dsh-generation-recovery' = '0.2.1'
    'dsh-loop-guard' = '0.1.2'
    'dsh-web-fetch-local' = '0.2.1'
    'dsh-web-search-searxng' = '0.2.1'
}
$savedEnvironment = @{}
foreach ($entry in Get-ChildItem Env:) {
    if ($entry.Name -like 'DSH_*' -or $entry.Name -eq 'CI') { $savedEnvironment[$entry.Name] = $entry.Value }
}
try {
    foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
    $env:CI = 'true'
    $env:DSH_HOME = $DataHome
    $downloadHeaders = @{ 'User-Agent' = 'Apoze-DSH-Windows-Installer'; Accept = 'application/vnd.github+json' }
    if ($GitHubToken) { $downloadHeaders.Authorization = 'Bearer ' + [Net.NetworkCredential]::new('', $GitHubToken).Password }
    $revisions = @{ 'deepseek-harness' = (Get-SourceRevision 'deepseek-harness' $CoreRef) }
    foreach ($name in $pluginVersions.Keys) { $revisions[$name] = Get-SourceRevision $name 'main' }
    $downloads = Join-Path $InstallRoot 'downloads'
    $core = Join-Path $InstallRoot 'core'
    $plugins = Join-Path $InstallRoot 'plugins'
    $toolRoot = Join-Path $InstallRoot 'tools'
    New-Item -ItemType Directory -Path $downloads, $plugins, $toolRoot, $DataHome -Force | Out-Null
    Write-Host 'Telechargement de la fork Apoze...'
    $coreRecord = Get-SourceArchive 'deepseek-harness' $core
    $manifest = Get-Content -LiteralPath (Join-Path $core 'package.json') -Raw | ConvertFrom-Json
    if ($manifest.version -ne '0.2.0-rc.1') { throw 'Version DSH inattendue ; adapter et revalider cet installateur.' }
    $env:DSH_CLIENT_COMMIT_HASH = $coreRecord.commit
    Invoke-Checked $npm @('install', '--prefix', $toolRoot, '--no-save', '--no-package-lock', '--no-audit', '--no-fund', 'pnpm@11.7.0')
    $pnpm = Join-Path $toolRoot 'node_modules\pnpm\bin\pnpm.cjs'
    Push-Location $core
    try {
        Invoke-Checked $node @($pnpm, 'install', '--frozen-lockfile')
        Invoke-Checked $node @($pnpm, 'run', 'build')
    } finally { Pop-Location }

    $packages = @{}
    foreach ($top in @('vendor', 'packages', 'apps')) {
        Get-ChildItem -LiteralPath (Join-Path $core $top) -Filter package.json -Depth 2 -File |
            Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' } | ForEach-Object {
                $package = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                $packages[$package.name] = $_.DirectoryName
            }
    }
    $records = @()
    foreach ($name in $pluginVersions.Keys) {
        Write-Host "Installation de $name..."
        $directory = Join-Path $plugins $name
        $record = Get-SourceArchive $name $directory
        $package = Get-Content -LiteralPath (Join-Path $directory 'package.json') -Raw | ConvertFrom-Json -AsHashtable
        if ($package.version -ne $pluginVersions[$name]) { throw "Version inattendue pour $name : $($package.version)." }
        $record.version = $package.version
        $records += $record
        Push-Location $directory
        try {
            Invoke-Checked $npm @('install', '--ignore-scripts', '--legacy-peer-deps', '--allow-remote=root', '--no-package-lock', '--no-audit', '--no-fund')
            $names = foreach ($field in @('dependencies', 'devDependencies', 'peerDependencies')) {
                if ($package.ContainsKey($field)) { $package[$field].Keys }
            }
            foreach ($dependency in ($names | Where-Object { $_ -like '@deepseek-ai/*' } | Sort-Object -Unique)) {
                if (-not $packages.ContainsKey($dependency)) { throw "Dependance absente de la fork : $dependency" }
                $link = [IO.Path]::GetFullPath((Join-Path $directory "node_modules\$dependency"))
                if (-not $link.StartsWith($directory + '\node_modules\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Chemin de dependance invalide.' }
                if (Test-Path -LiteralPath $link) {
                    $item = Get-Item -LiteralPath $link -Force
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($link) }
                    else { Remove-Item -LiteralPath $link -Recurse -Force }
                }
                New-Item -ItemType Directory -Path (Split-Path $link) -Force | Out-Null
                New-Item -ItemType Junction -Path $link -Target $packages[$dependency] | Out-Null
            }
            if ($package.ContainsKey('scripts') -and $package.scripts.ContainsKey('build')) { Invoke-Checked $npm @('run', 'build') }
        } finally { Pop-Location }
    }

    # JSON is valid YAML; these are profile overrides, never duplicate insert entries.
    $rows = @(@{ id = 'llm-ninfer'; disabled = (-not [bool]$NinferBaseUrl); config = @{
        provider = 'ninfer-local'; baseURL = $(if ($NinferBaseUrl) { $NinferBaseUrl } else { 'http://127.0.0.1:8000/v1' })
        credentialRef = 'NINFER_API_KEY'; models = @(@{
            id = $(if ($ModelId) { $ModelId } else { 'your-model-id' })
            contextWindow = $(if ($ContextWindow) { $ContextWindow } else { 131072 })
        })
    } })
    $webRows = @(@{ id = 'web'; config = @{ fetchProvider = 'local-safe-readability'; searchProvider = 'searxng' } })
    if ($SearxngUrl) { $webRows += @{ id = 'web-search-searxng'; config = @{ endpoint = $SearxngUrl } } }
    if ($ModelId) { $rows += @{ id = 'agent-default-model'; config = @{ provider = 'ninfer-local'; model = $ModelId } } }
    Set-Content -LiteralPath (Join-Path $DataHome 'cordis.patch.yml') -Value (ConvertTo-Json -InputObject $rows -Depth 15) -Encoding utf8
    $cli = Join-Path $core 'apps\cli\lib\bin.js'
    foreach ($profile in @('web', 'sdk', 'headless')) {
        $profileDir = Join-Path $DataHome "profiles\$profile"
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        if ($profile -eq 'web') { Set-Content -LiteralPath (Join-Path $profileDir 'cordis.patch.yml') -Value (ConvertTo-Json -InputObject $webRows -Depth 10) -Encoding utf8 }
        foreach ($name in $pluginVersions.Keys) {
            if ($profile -ne 'web' -and $name -notin @('dsh-llm-ninfer', 'dsh-generation-recovery', 'dsh-loop-guard')) { continue }
            $spec = 'link:' + (Join-Path $plugins $name).Replace('\', '/')
            Invoke-Checked $node @($cli, 'plugin', '--profile', $profile, 'add', $spec)
        }
    }
    # NInfer needs prepared-request admission in each agent's isolated compactor.
    # Derive presets from the downloaded fork, preserving its !!js expressions.
    $configurePresets = @'
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const [core, home] = process.argv.slice(2);
const yaml = createRequire(path.join(core, 'package.json'))('js-yaml');
class Expression { constructor(value) { this.value = value; } }
const schema = yaml.DEFAULT_SCHEMA.extend(new yaml.Type('tag:yaml.org,2002:js', {
  kind: 'scalar', construct: value => new Expression(value), instanceOf: Expression,
  represent: expression => expression.value,
}));
const read = file => yaml.load(fs.readFileSync(file, 'utf8'), { schema });
const global = read(path.join(home, 'cordis.patch.yml'));
const policy = {
  admission: 'prepared',
  thresholdRatio: 0.7, targetRatio: 0.4, retainRatio: 0.25,
  compactionRetries: 2, summarizationReasoningEffort: 'low',
  summarizationTools: false, maxTokens: 32768,
};
global.push({ id: 'compaction-basic', config: policy });
fs.writeFileSync(path.join(home, 'cordis.patch.yml'), yaml.dump(global, { schema, noRefs: true }));
const webFile = path.join(home, 'profiles', 'web', 'cordis.patch.yml');
const web = read(webFile);
let compactionGroup;
for (const id of ['standard', 'ptc', 'cordis', 'minimal']) {
  const declaration = read(path.join(core, 'packages', 'bundle', 'web-app', 'presets', `${id}.patch.yml`))[0].insert[0];
  let count = 0;
  function configure(rows) {
    for (const row of rows) {
      if (row.name === '@deepseek-ai/dsh-compaction-basic') {
        row.config = { ...row.config, ...policy }; count++;
      }
      if (Array.isArray(row.config)) configure(row.config);
    }
  }
  configure(declaration.config.plugins);
  if (id === 'standard') compactionGroup = declaration.config.plugins.find(row => row.id === 'compaction');
  if (count === 0) declaration.config.plugins.push(structuredClone(compactionGroup));
  web.push({ id: declaration.id, config: declaration.config });
}
fs.writeFileSync(webFile, yaml.dump(web, { schema, noRefs: true, lineWidth: 120 }));
'@
    $configurePath = Join-Path $InstallRoot 'configure-presets.mjs'
    Set-Content -LiteralPath $configurePath -Value $configurePresets -Encoding utf8
    Invoke-Checked $node @($configurePath, $core, $DataHome)
    $settings = @{
        dataHome = $DataHome; port = $Port; node = $node
        permissionMode = $(if ($FullAccess) { 'danger-full-access' } else { '' })
    }
    Set-Content -LiteralPath (Join-Path $InstallRoot 'launcher-settings.json') -Value ($settings | ConvertTo-Json) -Encoding utf8
    $launcher = @'
#Requires -Version 7.0
param([switch]$NoOpen)
$ErrorActionPreference = 'Stop'
$settings = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'launcher-settings.json') -Raw | ConvertFrom-Json
$env:DSH_HOME = $settings.dataHome
if ($settings.permissionMode) { $env:DSH_PERMISSION_MODE = $settings.permissionMode }
else { Remove-Item Env:DSH_PERMISSION_MODE -ErrorAction SilentlyContinue }
$cli = Join-Path $PSScriptRoot 'core\apps\cli\lib\bin.js'
$workspace = Join-Path $PSScriptRoot 'workspace'
$stdout = Join-Path $PSScriptRoot 'web.stdout.log'
$stderr = Join-Path $PSScriptRoot 'web.stderr.log'
$mutex = [Threading.Mutex]::new($false, "Local\DeepSeekHarnessWeb$($settings.port)")
$locked = $false
$started = $null
function Find-Server {
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like "*$cli*--profile web*" })
    if ($processes.Count -gt 1) { throw 'Plusieurs serveurs DSH existent deja.' }
    $owners = @(Get-NetTCPConnection -LocalPort $settings.port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
    foreach ($owner in $owners) {
        if ($processes.Count -ne 1 -or $processes[0].ProcessId -ne $owner) { throw 'Port utilise par une autre application ou installation.' }
    }
    if ($processes.Count -eq 1) { return $processes[0] }
    return $null
}
try {
    try { $locked = $mutex.WaitOne(120000) }
    catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Un autre lancement est toujours en cours.' }
    if ($null -eq (Find-Server)) {
        New-Item -ItemType Directory -Path $workspace -Force | Out-Null
        [IO.File]::WriteAllText($stdout, '')
        [IO.File]::WriteAllText($stderr, '')
        $arguments = '"{0}" --profile web --host 127.0.0.1 --port {1} --no-open' -f $cli, $settings.port
        $started = Start-Process -FilePath $settings.node -ArgumentList $arguments -WorkingDirectory $workspace -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    }
    $launchUrl = $null
    $pattern = 'http://127\.0\.0\.1:' + $settings.port + '/\?token=[^\s]+'
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($null -ne $started -and $started.HasExited) { throw 'DSH a quitte pendant le demarrage ; consulter web.stderr.log.' }
        $output = Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue
        if ($output) {
            $urls = [regex]::Matches($output, $pattern)
            if ($urls.Count -gt 0) {
                $candidate = $urls[$urls.Count - 1].Value
                try {
                    $response = Invoke-WebRequest -Uri $candidate -TimeoutSec 2
                    if ($response.StatusCode -eq 200) { $launchUrl = $candidate; break }
                } catch { # The listener may still be starting after emitting its URL.
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $launchUrl) { throw 'DSH ne repond pas ; consulter web.stderr.log.' }
    $null = Find-Server
} catch {
    Add-Content -LiteralPath (Join-Path $PSScriptRoot 'launcher.log') -Value "$(Get-Date -Format o) $($_.Exception.Message)"
    exit 1
} finally {
    if (Get-Variable downloadHeaders -ErrorAction SilentlyContinue) { $downloadHeaders.Clear() }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
if (-not $NoOpen) { Start-Process $launchUrl }
'@
    $launcherPath = Join-Path $InstallRoot 'Launch-DSH.ps1'
    Set-Content -LiteralPath $launcherPath -Value $launcher -Encoding utf8
    Set-Content -LiteralPath (Join-Path $InstallRoot 'installation.json') -Value (@{
        installedAt = (Get-Date).ToUniversalTime().ToString('o'); core = $coreRecord; plugins = $records
    } | ConvertTo-Json -Depth 10) -Encoding utf8
    if (-not $NoShortcut) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $pwsh
        $shortcut.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $launcherPath
        $shortcut.WorkingDirectory = $InstallRoot
        $shortcut.Description = 'DeepSeek Harness - Apoze'
        $shortcut.WindowStyle = 7
        $shortcut.Save()
    }
    Write-Host "Installation terminee : $InstallRoot"
    Write-Host 'Configurer les credentials NINFER_API_KEY dans DSH, puis activer/configurer NInfer dans Plugins si necessaire.'
    Write-Host 'Les archives sont conservees dans downloads ; les versions sont consignees dans installation.json.'
    if (-not $NoLaunch) { Invoke-Checked $pwsh @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcherPath) }
} finally {
    foreach ($entry in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'DSH_*' -or $_.Name -eq 'CI' })) {
        [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
    }
    foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key], 'Process') }
}
