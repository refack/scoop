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

    # Find current update repository from config
    $configRepo = get_config SCOOP_REPO
    if (!$configRepo) {
        $configRepo = 'https://github.com/ScoopInstaller/Scoop'
        set_config SCOOP_REPO $configRepo | Out-Null
    }

    # Find current update branch from config
    $configBranch = get_config SCOOP_BRANCH
    if (!$configBranch) {
        $configBranch = 'master'
        set_config SCOOP_BRANCH $configBranch | Out-Null
    }

    Write-Host 'Updating Scoop...'
    $currentdir = versiondir 'scoop' 'current'
    $oldShimHash = Get-ShimBodyHash (Get-ShimTemplate)
    if (!(Test-Path "$currentdir\.git")) {
        $newdir = "$currentdir\..\new"
        $olddir = "$currentdir\..\old"

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

    New-Shim "$currentdir\bin\scoop.ps1" $false

    $shimTemplate = Get-ShimTemplate
    # compare shim template hashes and trigger a refresh if needed
    if (!$oldShimHash -or $oldShimHash -ne (Get-ShimBodyHash $shimTemplate)) {
        Update-ShimInstance $shimTemplate
    }
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
        [string[]] $GitOutput = ""
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

function remove_obsolete_wiring($ctx, $old_manifest, $new_manifest) {
    # a later uninstall would delete the data through the old persist links
    unlink_persist_data $old_manifest $ctx.dir

    $shim_id = { param($entry) $target, $name, $null = Get-ShimDefinition $entry; "$name$([IO.Path]::GetExtension($target))" }
    $ids = @(arch_specific 'bin' $new_manifest $ctx.architecture | Where-Object { $_ -ne $null } | ForEach-Object { & $shim_id $_ })
    $removed = @(arch_specific 'bin' $old_manifest $ctx.architecture | Where-Object { $_ -ne $null } | Where-Object { (& $shim_id $_) -notin $ids })
    if ($removed) { Remove-ShimFromManifest $ctx.app @{ bin = $removed } $ctx.global $ctx.architecture }

    # the shortcut is edited in place, its removed arguments and icons would stay
    $shortcuts = @(arch_specific 'shortcuts' $old_manifest $ctx.architecture | Where-Object { $_ -ne $null })
    if ($shortcuts) { rm_startmenu_shortcuts @{ shortcuts = $shortcuts } $ctx.global $ctx.architecture }

    $current = "$(Split-Path $ctx.dir)\current"
    $paths = @(env_paths $new_manifest $current $ctx.persist_dir $ctx.architecture)
    # the old paths were expanded with the version directory, a nightly manifest keeps the name 'nightly'
    $version = Split-Path $ctx.dir -Leaf
    if (get_config NO_JUNCTION) {
        # without junctions the paths point at the version directory
        $removed = @(env_paths $old_manifest $ctx.dir $ctx.persist_dir $ctx.architecture)
    } else {
        $removed = @(env_paths $old_manifest $current $ctx.persist_dir $ctx.architecture) | Where-Object { $_ -notin $paths }
    }
    if ($removed) {
        Remove-Path -Path $removed -Global:$ctx.global
        Remove-Path -Path $removed -TargetEnvVar $scoopPathEnvVar -Global:$ctx.global
    }

    $names = @((arch_specific 'env_set' $new_manifest $ctx.architecture).PSObject.Properties.Name)
    $removed = @((arch_specific 'env_set' $old_manifest $ctx.architecture).PSObject.Properties.Name) | Where-Object { $_ -notin $names }
    foreach ($var in $removed) {
        Set-EnvVar -Name $var -Value $null -Global:$ctx.global
        Remove-Item "env:\$var" -ErrorAction SilentlyContinue
    }

    if ($old_manifest.psmodule.name -and $old_manifest.psmodule.name -ne $new_manifest.psmodule.name) {
        uninstall_psmodule $old_manifest $ctx.dir $ctx.global
    }
}

function restore_app($ctx, $old_manifest, $old_version, $backup) {
    # the old manifest expands $version, which still names the failed update
    $version = $old_version
    if ($backup -and (Test-Path $backup)) {
        try {
            # the backup would land inside the recreated directory
            if (Test-Path $ctx.dir) { Remove-Item $ctx.dir -Recurse -Force -ErrorAction Stop }
            Move-Item $backup $ctx.dir -ErrorAction Stop
        } catch {
            warn "'$($ctx.app)' ($old_version) could not be restored: $($_.Exception.Message)"
            return
        }
    }
    if (installed_manifest $ctx.app $old_version $ctx.global) {
        Write-Host "Restoring '$($ctx.app)' ($old_version)"
        $original_dir = $ctx.dir
        try {
            $dir = link_current $ctx.dir
            link_app $old_manifest $dir $original_dir $ctx.persist_dir $ctx.global $ctx.architecture
        } catch {
            warn "'$($ctx.app)' ($old_version) was restored, but its links could not be recreated: $($_.Exception.Message)"
        }
    } else {
        warn "'$($ctx.app)' ($old_version) cannot be restored; its files were removed by the uninstaller."
    }
}

function update_app($app, $global, $force = $false, $quiet = $false, $independent, $suggested, $failed, $use_cache = $true, $check_hash = $true, $cleanup = $false) {
    $app_key = if ($global) { "$app (global)" } else { $app }
    $app_name = $app
    $unlinked = $false
    $old_version = Select-CurrentVersion -AppName $app -Global:$global
    $old_manifest = installed_manifest $app $old_version $global
    $install = install_info $app $old_version $global

    # re-use architecture, bucket and url from first install
    $architecture = Format-ArchitectureString $install.architecture
    $bucket = $install.bucket
    $url = $install.url

    # -f on an @version pin re-resolves against the bucket HEAD
    $pin_broken = $force -and $null -eq $bucket -and ($url -eq (usermanifest $app))
    if ($pin_broken) {
        $scanned, $bucket = Find-AppBucket $app
        if ($scanned) {
            $manifest = $scanned
            $url = $null
        } else {
            $manifest = manifest $app $null $url
        }
    } else {
        if ($null -eq $bucket -and !$url) { $bucket = 'main' }
        $manifest = manifest $app $bucket $url
    }
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
        $failed[$app_key] = 'no manifest available'
        return
    }

    Write-Host "Updating '$app' ($old_version -> $version)"

    $failed_deps = failed_deps $manifest $failed
    if ($failed_deps.Count -gt 0) {
        error "'$app' depends on $($failed_deps -join ', '), which failed."
        $failed[$app_key] = "dependency failed: $($failed_deps -join ', ')"
        return
    }

    #region Workaround for #2952
    if (test_running_process $app $global) {
        Write-Host 'Running process detected, skip updating.'
        $failed[$app_key] = 'skipped: running process'
        return
    }
    #endregion Workaround for #2952

    # region Workaround
    # Workaround for https://github.com/ScoopInstaller/Scoop/issues/2220 until install is refactored
    # Remove and replace whole region after proper fix
    Write-Host 'Downloading new version'
    if (Test-Aria2Enabled) {
        if (!(Invoke-CachedAria2Download $app $version $manifest $architecture $cachedir $manifest.cookie $use_cache $check_hash)) {
            $failed[$app_key] = 'download failed'
            return
        }
    } else {
        $urls = script:url $manifest $architecture

        foreach ($url in $urls) {
            try {
                Invoke-CachedDownload $app $version $url $null $manifest.cookie $use_cache
            } catch {
                Write-Host -f darkred $_
                error "URL $url is not valid"
                error $(new_issue_msg $app $bucket 'download failed')
                $failed[$app_key] = 'download failed'
                return
            }

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
                    error $(new_issue_msg $app $bucket 'hash check failed')
                    $failed[$app_key] = 'hash check failed'
                    return
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
    $ctx = [PSCustomObject]@{
        app          = $app
        dir          = $dir
        persist_dir  = $persist_dir
        global       = $global
        architecture = $architecture
    }

    try {
        Invoke-HookScript -HookType 'pre_uninstall' -Manifest $old_manifest -Arch $architecture

        Write-Host "Uninstalling '$app' ($old_version)"
        if (!(Invoke-Installer -Path $dir -Manifest $old_manifest -ProcessorArchitecture $architecture -Global:$global -Uninstall)) {
            $failed[$app_key] = 'uninstaller failed'
            return
        }
        $unlinked = $true
        remove_obsolete_wiring $ctx $old_manifest $manifest

        $backup = $null
        if ($force -and ($old_version -eq $version)) {
            $new_backup = "$dir/../_$version.old"
            if (Test-Path $new_backup) {
                $i = 1
                While (Test-Path "$new_backup($i)") {
                    $i++
                }
                $new_backup = "$new_backup($i)"
            }
            Move-Item $dir $new_backup -ErrorAction Stop
            $backup = $new_backup
        }

        Invoke-HookScript -HookType 'post_uninstall' -Manifest $old_manifest -Arch $architecture

    # 'cleanup' needs the bare name, but the next lines qualify it with the bucket or url
    $bare_app = $app

        if ($bucket) {
            # add bucket name it was installed from
            $app = "$bucket/$app"
        }
        if ($install.url -and (!$pin_broken -or !$bucket)) {
            # use the url of the install json if the application was installed through url
            $app = $install.url
        }

        if (-not $independent) {
            # Also add missing dependencies
            $apps = @(Get-Dependency $app $architecture) -ne $app
            $apps.Where({ !(installed $_) }) | ForEach-Object { install_app $_ $architecture $global $suggested $failed $use_cache $check_hash -NoManifestPrompt }
        }

        # The new version has already been downloaded (and hash-checked) above,
        # so re-install it from the cache instead of downloading it a second time.
        # the dependency failures live in the same table
        install_app $app $architecture $global $suggested $failed $true $check_hash -NoManifestPrompt
        # the scope specific key keeps the other scope from restoring
        if ($failed.ContainsKey($app_key)) {
            restore_app $ctx $old_manifest $old_version $backup

        } elseif ($cleanup -and ((Select-CurrentVersion -AppName $bare_app -Global:$global) -eq $version)) {
            # a failure here must not prevent the remaining apps from being updated
            try {
                cleanup $bare_app $global $false $false
            } catch {
                warn "Failed to clean up old versions of '$bare_app': $($_.Exception.Message)"
            }
        }
    } catch {
        $failed[$app_key] = $_.Exception.Message
        error $_.Exception.Message
        if ($unlinked) {
            restore_app $ctx $old_manifest $old_version $backup
        }
    }
}
