# Usage: scoop status
# Summary: Show status and check for new app versions
# Help: Options:
#   -l, --local         Checks the status for only the locally installed apps,
#                       and disables remote fetching/checking for Scoop and buckets

. "$PSScriptRoot\..\lib\getopt.ps1"
. "$PSScriptRoot\..\lib\download.ps1" # 'Get-UserAgent'
. "$PSScriptRoot\..\lib\manifest.ps1" # 'manifest' 'parse_json' "install_info"
. "$PSScriptRoot\..\lib\versions.ps1" # 'Select-CurrentVersion'
. "$PSScriptRoot\..\lib\download.ps1" # 'Get-UserAgent'

$opt, $apps, $err = getopt $args 'lu:' 'local', 'update'

# check if scoop needs updating
$currentdir = versiondir 'scoop' 'current'
$needs_update = $false
$bucket_needs_update = $false
$script:network_failure = $false
$only_local = $opt.local
if (!(Get-Command git -ErrorAction SilentlyContinue)) { $only_local = $true }
$list = @()
if (!(Get-FormatData ScoopStatus)) {
    Update-FormatData "$PSScriptRoot\..\supporting\formats\ScoopTypes.Format.ps1xml"
}

function Test-UpdateStatus($repopath) {
    if (Test-Path "$repopath\.git") {
        Invoke-Git -Path $repopath -ArgumentList @('fetch', '-q', 'origin')
        $script:network_failure = 128 -eq $LASTEXITCODE
        $branch  = Invoke-Git -Path $repopath -ArgumentList @('branch', '--show-current')
        $commits = Invoke-Git -Path $repopath -ArgumentList @('log', "HEAD..origin/$branch", '--oneline')
        if ($commits) { return $true }
        else { return $false }
    } else {
        return $true
    }
}

$update_completed = $false
if (!$only_local) {
    if ($opt.update) {
        $pwsh_path = (Get-Process -Id $PID).Path
        & $pwsh_path -Command "scoop update"
        $update_completed = 0 -eq $LASTEXITCODE
    }

    if ($update_completed) {
        $needs_update = $false
        $bucket_needs_update = $false
    } else {
        $needs_update = Test-UpdateStatus $currentdir
        foreach ($bucket in Get-LocalBucket) {
            if (Test-UpdateStatus (Find-BucketDirectory $bucket -Root)) {
                $bucket_needs_update = $true
                break
            }
        }
    }
}

if ($update_completed) {
    info "Already run 'scoop update'."
} elseif ($needs_update) {
    warn "Scoop out of date. Run 'scoop update' to get the latest changes."
} elseif ($bucket_needs_update) {
    warn "Scoop bucket(s) out of date. Run 'scoop update' to get the latest changes."
} elseif (!$script:network_failure -and !$only_local) {
    success 'Scoop is up to date.'
}

$true, $false | ForEach-Object { # local and global apps
    $global = $_
    $dir = appsdir $global
    if (!(Test-Path $dir)) { return }

    $apps = Get-ChildItem $dir | Where-Object name -ne 'scoop'
    $apps | ForEach-Object {
        $app = $_.name
        $status = app_status $app $global
        if (!$status.outdated -and !$status.failed -and !$status.deprecated -and !$status.removed -and !$status.missing_deps) { return }

        $item = [ordered]@{}
        $item.Name = $app
        $item.'Installed Version' = $status.version
        $item.'Latest Version' = if ($status.outdated) { $status.latest_version } else { "" }
        $item.'Missing Dependencies' = $status.missing_deps -Split ' ' -Join ' | '
        $info = @()
        if ($status.failed)     { $info += 'Install failed' }
        if ($status.hold)       { $info += 'Held package' }
        if ($status.deprecated) { $info += 'Deprecated' }
        if ($status.removed)    { $info += 'Manifest removed' }
        $item.Info = $info -join ', '
        $list += [PSCustomObject]$item
    }
}

if ($list.Length -eq 0 -and !$needs_update -and !$bucket_needs_update -and !$script:network_failure) {
    success 'Everything is ok!'
}

$list | Add-Member -TypeName ScoopStatus -PassThru

exit 0
