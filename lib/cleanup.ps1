# Windows refuses to delete a file that is open or section-mapped, but it does still allow
# renaming one, so a version directory that is in use is moved aside rather than removed,
# under the same '_<version>.old' name 'scoop update --force' uses: 'Get-InstalledVersion'
# already ignores that shape, and a later cleanup sweeps it once the app is closed.
# This is best effort - the rename is refused in turn if anything holds a handle on a
# directory in there, which a process whose working directory is inside the app does.
function park_version_dir($dir) {
    $appDir = Split-Path $dir
    $version = Split-Path $dir -Leaf
    $parked = "$appDir\_$version.old"
    $i = 1
    while (Test-Path $parked) {
        $parked = "$appDir\_$version.old($i)"
        $i++
    }
    # not 'Move-Item': the provider quietly falls back to a recursive copy-and-delete when
    # the rename is refused, duplicating the very files it then cannot remove. Parking has
    # to be all or nothing, so rename directly and let a refusal surface as an error.
    [System.IO.Directory]::Move($dir, $parked)
    return (Split-Path $parked -Leaf)
}

function cleanup($app, $global, $verbose, $cache) {
    $current_version = Select-CurrentVersion -AppName $app -Global:$global
    if ($cache) {
        Remove-Item "$cachedir\$app#*" -Exclude "$app#$current_version#*" -ErrorAction Ignore
    }
    $appDir = appdir $app $global
    if (!(Test-Path $appDir)) {
        if ($verbose) { warn "'$app' is not installed" }
        return
    }
    $versions = @(Get-ChildItem $appDir -Directory -Name | Where-Object { $current_version -ne $_ -and $_ -ne 'current' })
    if (!$versions) {
        if ($verbose) { success "$app is already clean" }
        return
    }

    Write-Host -f yellow "Removing $app`:" -NoNewline
    $parked = @()
    $failed = @()
    foreach ($version in $versions) {
        Write-Host " $version" -NoNewline
        $dir = versiondir $app $version $global
        # unlink all potential old link before doing recursive Remove-Item
        unlink_persist_data (installed_manifest $app $version $global) $dir
        try {
            Remove-Item $dir -ErrorAction Stop -Recurse -Force
        } catch [System.UnauthorizedAccessException], [System.IO.IOException] {
            Write-Host ' (in use)' -f darkgray -NoNewline
            # an earlier run already parked this one and it is still held, so leave it be
            # rather than renaming it a second time
            if ($version -like '_*.old*') { continue }
            try {
                $parked += park_version_dir $dir
            } catch {
                $failed += $version
                Write-Host ' (failed)' -f darkred -NoNewline
            }
        }
    }
    Write-Host ''

    if ($parked) {
        warn "Files of '$app' are still in use; moved $(($parked | ForEach-Object { "'$_'" }) -join ', ') aside."
        warn "Close the app and run 'scoop cleanup $app' to reclaim the space."
    }
    if ($failed) {
        warn "Could not remove $(($failed | ForEach-Object { "'$_'" }) -join ', ') of '$app'."
    }

    $leftVersions = @(Get-ChildItem $appDir)
    if ($leftVersions.Length -eq 1 -and $leftVersions[0].Name -eq 'current' -and $leftVersions[0].LinkType) {
        attrib $leftVersions[0].FullName -R /L
        Remove-Item $leftVersions[0].FullName -Force -ErrorAction Ignore
        $leftVersions = @(Get-ChildItem $appDir)
    }
    if (!$leftVersions) {
        Remove-Item $appDir -Force -ErrorAction Ignore
    }
}
