# Usage: scoop update <app> [options]
# Summary: Update apps, or Scoop itself
# Help: 'scoop update' updates Scoop to the latest version.
# 'scoop update <app>' installs a new version of that app, if there is one.
#
# You can use '*' in place of <app> to update all apps.
#
# Options:
#   -f, --force            Force update even when there isn't a newer version
#   -g, --global           Update a globally installed app
#   -i, --independent      Don't install dependencies automatically
#   -k, --no-cache         Don't use the download cache
#   -s, --skip-hash-check  Skip hash validation (use with caution!)
#   -q, --quiet            Hide extraneous messages
#   -a, --all              Update all apps (alternative to '*')
#   -c, --cleanup          Remove the old versions of each app that is updated

. "$PSScriptRoot\..\lib\getopt.ps1"
. "$PSScriptRoot\..\lib\json.ps1" # 'save_install_info' in 'manifest.ps1' (indirectly)
. "$PSScriptRoot\..\lib\system.ps1"
. "$PSScriptRoot\..\lib\shortcuts.ps1"
. "$PSScriptRoot\..\lib\psmodules.ps1"
. "$PSScriptRoot\..\lib\decompress.ps1"
. "$PSScriptRoot\..\lib\manifest.ps1"
. "$PSScriptRoot\..\lib\versions.ps1"
. "$PSScriptRoot\..\lib\depends.ps1"
. "$PSScriptRoot\..\lib\install.ps1"
. "$PSScriptRoot\..\lib\download.ps1"
. "$PSScriptRoot\..\lib\cleanup.ps1"
if (get_config USE_SQLITE_CACHE) {
    . "$PSScriptRoot\..\lib\database.ps1"
}

$opt, $apps, $err = getopt $args 'gfiksqac' 'global', 'force', 'independent', 'no-cache', 'skip-hash-check', 'quiet', 'all', 'cleanup'
if ($err) { error "scoop update: $err"; exit 1 }
$global = $opt.g -or $opt.global
$force = $opt.f -or $opt.force
$check_hash = !($opt.s -or $opt.'skip-hash-check')
$use_cache = !($opt.k -or $opt.'no-cache')
$quiet = $opt.q -or $opt.quiet
$independent = $opt.i -or $opt.independent
$all = $opt.a -or $opt.all
$cleanup = $opt.c -or $opt.cleanup

# load config
$configRepo = get_config SCOOP_REPO
if (!$configRepo) {
    $configRepo = 'https://github.com/ScoopInstaller/Scoop'
    set_config SCOOP_REPO $configRepo | Out-Null
}

# Find current update channel from config
$configBranch = get_config SCOOP_BRANCH
if (!$configBranch) {
    $configBranch = 'master'
    set_config SCOOP_BRANCH $configBranch | Out-Null
}

if (($PSVersionTable.PSVersion.Major) -lt 5) {
    # check powershell version
    Write-Output 'PowerShell 5 or later is required to run Scoop.'
    Write-Output 'Upgrade PowerShell: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-core-on-windows'
    break
}
$show_update_log = get_config SHOW_UPDATE_LOG $true

function Sync-Scoop {
    [CmdletBinding()]
    Param (
        [Switch]$Log
    )
    # Test if Scoop Core is hold
    if (Test-ScoopCoreOnHold) {
        return
    }

    # check for git
    if (!(Test-GitAvailable)) { abort "Scoop uses Git to update itself. Run 'scoop install git' and try again." }

    Write-Host 'Updating Scoop...'
    $currentdir = versiondir 'scoop' 'current'
    $is_git = Test-Path "$currentdir\.git"
    if (!$is_git) {
        $newdir = "$currentdir\..\new"

        # get git scoop
        Invoke-Git -ArgumentList @('clone', '-q', $configRepo, '--branch', $configBranch, '--single-branch', $newdir)

        # check if scoop was successful downloaded
        if (!(Test-Path "$newdir\bin\scoop.ps1")) {
            Remove-Item $newdir -Force -Recurse
            abort "Scoop download failed. If this appears several times, try removing SCOOP_REPO by 'scoop config rm SCOOP_REPO'"
        } else {
            # replace non-git scoop with the git version
            try {
                Rename-Item $currentdir 'old' -ErrorAction Stop
                Rename-Item $newdir 'current' -ErrorAction Stop
            } catch {
                Write-Warning $_
                abort "Scoop update failed. Folder in use. Please rename folders $currentdir to ``old`` and $newdir to ``current``."
            }
        }
    } else {
        if (Test-Path "$currentdir\..\old") {
            Remove-Item "$currentdir\..\old" -Recurse -Force -ErrorAction SilentlyContinue
        }

        $previousCommit = Invoke-Git -Path $currentdir -ArgumentList @('rev-parse', 'HEAD')
        $currentRepo = Invoke-Git -Path $currentdir -ArgumentList @('config', 'remote.origin.url')
        $currentBranch = Invoke-Git -Path $currentdir -ArgumentList @('branch')

        $isRepoChanged = !($currentRepo -match $configRepo)
        $isBranchChanged = !($currentBranch -match "\*\s+$configBranch")

        # Stash uncommitted changes
        if (Invoke-Git -Path $currentdir -ArgumentList @('diff', 'HEAD', '--name-only')) {
            if (get_config AUTOSTASH_ON_CONFLICT) {
                warn 'Uncommitted changes detected. Stashing...'
                Invoke-Git -Path $currentdir -ArgumentList @('stash', 'push', '-m', "WIP at $([System.DateTime]::Now.ToString('o'))", '-u', '-q')
            } else {
                warn 'Uncommitted changes detected. Update aborted.'
                return
            }
        }

        # Change remote url if the repo is changed
        if ($isRepoChanged) {
            Invoke-Git -Path $currentdir -ArgumentList @('config', 'remote.origin.url', $configRepo)
        }

        # Fetch and reset local repo if the repo or the branch is changed
        if ($isRepoChanged -or $isBranchChanged) {
            # Reset git fetch refs, so that it can fetch all branches (GH-3368)
            Invoke-Git -Path $currentdir -ArgumentList @('config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*')
            # fetch remote branch
            Invoke-Git -Path $currentdir -ArgumentList @('fetch', '--force', 'origin', "refs/heads/$configBranch`:refs/remotes/origin/$configBranch", '-q')
            # checkout and track the branch
            Invoke-Git -Path $currentdir -ArgumentList @('checkout', '-B', $configBranch, '-t', "origin/$configBranch", '-q')
            # reset branch HEAD
            Invoke-Git -Path $currentdir -ArgumentList @('reset', '--hard', "origin/$configBranch", '-q')
        } else {
            Invoke-Git -Path $currentdir -ArgumentList @('pull', '--tags', '--force', '-q')
        }

        $res = $lastexitcode
        if ($Log) {
            Invoke-GitLog -Path $currentdir -CommitHash $previousCommit
        }

        if ($res -ne 0) {
            abort 'Update failed.'
        }
    }

    shim "$currentdir\bin\scoop.ps1" $false
}


function Parse-GitPull {
    # example ret:
    #
    # POST git-upload-pack (226 bytes)
    # From https://github.com/ScoopInstaller/Main
    # = [up to date]          master     -> origin/master
    # = [up to date]          fix-test   -> origin/fix-test
    # Updating 5cf69323d..3d40cf562
    # Fast-forward
    # bucket/azure-cli.json            |  6 +++---
    # bucket/azure-ps.json             | 10 +++++-----
    # bucket/balena-cli.json           |  6 ------
    # bucket/terragrunt.json           | 10 +++++-----
    # bucket/tflint.json               | 10 +++++-----
    # bucket/tinymist.json             | 34 ++++++++++++++++++++++++++++++++++
    # bucket/traefik.json              | 14 +++++++-------

    param(
        [Parameter(Mandatory = $true)]
        [string[]] $GitOutput
    )

    $hashRange = $null
    $files = [System.Collections.Generic.List[object]]::new()
    # Use a dictionary to handle multiple lines referring to the same file (e.g. diffstat and rename line)
    $fileInfo = [ordered]@{}

    # --- 1. Find Hash Range ---
    $hashLine = $GitOutput | Select-String -Pattern '^Updating ([\da-f\.]+\.\.[\da-f\.]+)'
    if ($hashLine) {
        $hashRange = $hashLine.Matches[0].Groups[1].Value
    }

    # --- 2. Parse File Statuses ---
    # Process explicit mode changes first, as they are more reliable
    foreach ($line in $GitOutput) {
        if ($line -match '^\s*create mode \d+ (.+)') {
            $filePath = $matches[1].Trim()
            $fileInfo[$filePath] = @{ Path = $filePath; Status = 'added' }
        }
        elseif ($line -match '^\s*delete mode \d+ (.+)') {
            $filePath = $matches[1].Trim()
            $fileInfo[$filePath] = @{ Path = $filePath; Status = 'deleted' }
        }
        elseif ($line -match '^\s*rename (.+?)(?: => (.+))? \(([\d%]+)\)') {
            $renamePart = $matches[1].Trim()
            $toPart = $matches[2]

            if ($renamePart -match '^{(.+?)\s+=>\s+(.+?)}/(.+)') {
                $oldDir = $matches[1]
                $newDir = $matches[2]
                $file = $matches[3]
                $oldPath = Join-Path $oldDir $file
                $newPath = Join-Path $newDir $file
                $fileInfo[$newPath] = @{ Path = $newPath; Status = 'renamed'; OldPath = $oldPath }
            } elseif ($toPart) {
                $oldPath = $renamePart
                $newPath = $toPart.Trim()
                $fileInfo[$newPath] = @{ Path = $newPath; Status = 'renamed'; OldPath = $oldPath }
            }
        }
    }

    # Process diffstat lines for files not already identified by explicit mode changes
    foreach ($line in $GitOutput) {
        if ($line -match '^\s*(?<path>.+?)\s+\|\s+\d+\s+(?<changes>[+\-]+)$') {
            $filePath = $matches.path.Trim()
            if ($fileInfo.Contains($filePath)) { continue }

            $changes = $matches.changes
            if ($changes.Contains('+') -and -not $changes.Contains('-')) {
                $fileInfo[$filePath] = @{ Path = $filePath; Status = 'added' }
            } elseif ($changes.Contains('-') -and -not $changes.Contains('+')) {
                $fileInfo[$filePath] = @{ Path = $filePath; Status = 'deleted' }
            } else {
                $fileInfo[$filePath] = @{ Path = $filePath; Status = 'changed' }
            }
        }
    }

    # Convert the dictionary to a list of PSCustomObjects
    foreach ($key in $fileInfo.Keys) {
        $files.Add([PSCustomObject]$fileInfo[$key])
    }

    return $hashRange, $files
}


function Sync-Bucket {
    Param (
        [Switch]$Log
    )
    Write-Host 'Updating Buckets...'

    if (!(Test-Path (Join-Path (Find-BucketDirectory 'main' -Root) '.git'))) {
        info "Converting 'main' bucket to git repo..."
        $status = rm_bucket 'main'
        if ($status -ne 0) {
            abort "Failed to remove local 'main' bucket."
        }
        $status = add_bucket 'main' (known_bucket_repo 'main')
        if ($status -ne 0) {
            abort "Failed to add remote 'main' bucket."
        }
    }


    $buckets = Get-LocalBucket | ForEach-Object {
        $path = Find-BucketDirectory $_ -Root
        $ret  = @{
            name  = $_
            is_git = Test-Path -PathType Container (Join-Path $path '.git')
            path  = $path
        }
        if (-not $ret.is_git) { Write-Host "'$($ret.name)' is not a git repository. Skipped." }
        return $ret
    }

    $retList = $buckets | Where-Object is_git | ForEach-Object {
        $bucketName = $_.name
        $bucketLoc = $_.path
        # $bucketLocInner = Find-BucketDirectory $bucketName

        Write-Host "Updating Bucket $bucketName ($bucketLoc)"

        $git_pull_ret = Invoke-Git -Path $bucketLoc -ArgumentList @('pull', '--verbose')
        $hashRange, $affectedFiles = Parse-GitPull $git_pull_ret

        if ($Log -and $hashRange) {
            Invoke-GitLog -Path $bucketLoc -Name $bucketName -CommitHash $hashRange
        }

        return $affectedFiles
    }
    if ((get_config USE_SQLITE_CACHE) -and $retList) {
        info 'Updating cache...'
        Set-ScoopDB -Path $updatedFiles
        $removedFiles | Remove-ScoopDBItem
    }
}

function update($app, $global, $quiet = $false, $independent, $suggested, $use_cache = $true, $check_hash = $true) {
    $old_version = Select-CurrentVersion -AppName $app -Global:$global
    $old_manifest = installed_manifest $app $old_version $global
    $install = install_info $app $old_version $global

    # re-use architecture, bucket and url from first install
    $architecture = Format-ArchitectureString $install.architecture
    $bucket = $install.bucket
    if ($null -eq $bucket) {
        $bucket = 'main'
    }
    $url = $install.url

    $manifest = manifest $app $bucket $url
    $version = $manifest.version
    $is_nightly = $version -eq 'nightly'
    if ($is_nightly) {
        $version = nightly_version $quiet
        $check_hash = $false
    }

    if (!$force -and ($old_version -eq $version)) {
        if (!$quiet) {
            warn "The latest version of '$app' ($version) is already installed."
        }
        return
    }
    if (!$version) {
        # installed from a custom bucket/no longer supported
        error "No manifest available for '$app'."
        return
    }

    Write-Host "Updating '$app' ($old_version -> $version)"

    #region Workaround for #2952
    if (test_running_process $app $global) {
        Write-Host 'Running process detected, skip updating.'
        return
    }
    #endregion Workaround for #2952

    # region Workaround
    # Workaround for https://github.com/ScoopInstaller/Scoop/issues/2220 until install is refactored
    # Remove and replace whole region after proper fix
    Write-Host 'Downloading new version'
    if (Test-Aria2Enabled) {
        Invoke-CachedAria2Download $app $version $manifest $architecture $cachedir $manifest.cookie $true $check_hash
    } else {
        $urls = script:url $manifest $architecture

        foreach ($url in $urls) {
            Invoke-CachedDownload $app $version $url $null $manifest.cookie $true

            if ($check_hash) {
                $manifest_hash = hash_for_url $manifest $url $architecture
                $source = cache_path $app $version $url
                $ok, $err = check_hash $source $manifest_hash $(show_app $app $bucket)

                if (!$ok) {
                    error $err
                    if (Test-Path $source) {
                        # rm cached file
                        Remove-Item -Force $source
                    }
                    if ($url.Contains('sourceforge.net')) {
                        Write-Host -f yellow 'SourceForge.net is known for causing hash validation fails. Please try again before opening a ticket.'
                    }
                    abort $(new_issue_msg $app $bucket 'hash check failed')
                }
            }
        }
    }
    # There is no need to check hash again while installing
    $check_hash = $false
    # endregion Workaround

    $dir = versiondir $app $old_version $global
    # $persist_dir needed for the script context, assigning it this way hides it from PSScriptAnalyzer
    Set-Variable -Name persist_dir -Value (persistdir $app $global)

    Invoke-HookScript -HookType 'pre_uninstall' -Manifest $old_manifest -Arch $architecture

    Write-Host "Uninstalling '$app' ($old_version)"
    Invoke-Installer -Path $dir -Manifest $old_manifest -ProcessorArchitecture $architecture -Global:$global -Uninstall
    rm_shims $app $old_manifest $global $architecture

    # If a junction was used during install, that will have been used
    # as the reference directory. Otherwise it will just be the version
    # directory.
    $refdir = unlink_current $dir
    uninstall_psmodule $old_manifest $refdir $global
    env_rm_path $old_manifest $refdir $global $architecture
    env_rm $old_manifest $global $architecture

    if ($force -and ($old_version -eq $version)) {
        if (!(Test-Path "$dir/../_$version.old")) {
            Move-Item "$dir" "$dir/../_$version.old"
        } else {
            $i = 1
            While (Test-Path "$dir/../_$version.old($i)") {
                $i++
            }
            Move-Item "$dir" "$dir/../_$version.old($i)"
        }
    }

    Invoke-HookScript -HookType 'post_uninstall' -Manifest $old_manifest -Arch $architecture

    # 'cleanup' needs the bare name, but the next lines qualify it with the bucket or url
    $bare_app = $app

    if ($bucket) {
        # add bucket name it was installed from
        $app = "$bucket/$app"
    }
    if ($install.url) {
        # use the url of the install json if the application was installed through url
        $app = $install.url
    }

    if ($independent) {
        install_app $app $architecture $global $suggested $use_cache $check_hash
    } else {
        # Also add missing dependencies
        $apps = @(Get-Dependency $app $architecture) -ne $app
        ensure_none_failed $apps
        $apps.Where({ !(installed $_) }) + $app | ForEach-Object { install_app $_ $architecture $global $suggested $use_cache $check_hash }
    }

    # only clean up once the new version is the one actually linked, so a failed
    # install keeps the old version around to fall back on
    if ($cleanup -and ((Select-CurrentVersion -AppName $bare_app -Global:$global) -eq $version)) {
        # a failure here must not prevent the remaining apps from being updated
        try {
            cleanup $bare_app $global $false $false
        } catch {
            warn "Failed to clean up old versions of '$bare_app': $($_.Exception.Message)"
        }
    }
}

if (-not ($apps -or $all)) {
    if ($global) {
        error 'scoop update: --global is invalid when <app> is not specified.'
        exit 1
    }
    if (!$use_cache) {
        error 'scoop update: --no-cache is invalid when <app> is not specified.'
        exit 1
    }
    if ($cleanup) {
        error 'scoop update: --cleanup is invalid when <app> is not specified.'
        exit 1
    }
    Sync-Scoop -Log:$show_update_log
    Sync-Bucket -Log:$show_update_log
    set_config LAST_UPDATE ([System.DateTime]::Now.ToString('o')) | Out-Null
    success 'Scoop was updated successfully!'
} else {
    if ($global -and !(is_admin)) {
        error 'You need admin rights to update global apps.'; exit 1
    }

    $outdated = @()
    $updateScoop = $null -ne ($apps | Where-Object { $_ -eq 'scoop' }) -or (is_scoop_outdated)
    $apps = $apps | Where-Object { $_ -ne 'scoop' }
    $apps_param = $apps

    if ($updateScoop) {
        Sync-Scoop -Log:$show_update_log
        Sync-Bucket -Log:$show_update_log
        set_config LAST_UPDATE ([System.DateTime]::Now.ToString('o')) | Out-Null
        success 'Scoop was updated successfully!'
    }

    if ($apps_param -eq '*' -or $all) {
        $apps = applist (installed_apps $false) $false
        if ($global) {
            $apps += applist (installed_apps $true) $true
        }
    } else {
        if ($apps_param) {
            $apps = Confirm-InstallationStatus $apps_param -Global:$global
        }
    }
    if ($apps) {
        $apps | ForEach-Object {
            ($app, $global) = $_
            $status = app_status $app $global
            if ($status.installed -and ($force -or $status.outdated)) {
                if (!$status.hold) {
                    $outdated += applist $app $global
                    Write-Host -f yellow ("$app`: $($status.version) -> $($status.latest_version){0}" -f ('', ' (global)')[$global])
                } else {
                    warn "'$app' is held to version $($status.version)"
                }
            } elseif ($apps_param -ne '*' -and !$all) {
                if ($status.installed) {
                    ensure_none_failed $app
                    Write-Host "$app`: $($status.version) (latest version)" -ForegroundColor Green
                } else {
                    info 'Please reinstall it or fix the manifest.'
                }
            }
        }

        if ($outdated -and ((Test-Aria2Enabled) -and (get_config 'aria2-warning-enabled' $true))) {
            warn "Scoop uses 'aria2c' for multi-connection downloads."
            warn "Should it cause issues, run 'scoop config aria2-enabled false' to disable it."
            warn "To disable this warning, run 'scoop config aria2-warning-enabled false'."
        }
        if ($outdated.Length -gt 1) {
            Write-Host -f DarkCyan "Updating $($outdated.Length) outdated apps:"
        } elseif ($outdated.Length -eq 0) {
            Write-Host -f Green "Latest versions for all apps are installed! For more information try 'scoop status'"
        } else {
            Write-Host -f DarkCyan 'Updating one outdated app:'
        }
    }

    $suggested = @{}
    # $outdated is a list of ($app, $global) tuples
    $outdated | ForEach-Object { update @_ $quiet $independent $suggested $use_cache $check_hash }
}

exit 0
