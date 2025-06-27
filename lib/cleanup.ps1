function cleanup($app, $global, $verbose, $cache) {
    $current_version = Select-CurrentVersion -AppName $app -Global:$global
    if ($cache) {
        Remove-Item "$cachedir\$app#*" -Exclude "$app#$current_version#*"
    }
    $appDir = appdir $app $global
    $versions = Get-ChildItem $appDir -Name
    $versions = $versions | Where-Object { $current_version -ne $_ -and $_ -ne 'current' }
    if (!$versions) {
        if ($verbose) { success "$app is already clean" }
        return
    }

    Write-Host -f yellow "Removing $app`:" -NoNewline
    $versions | ForEach-Object {
        $version = $_
        Write-Host " $version" -NoNewline
        $dir = versiondir $app $version $global
        # unlink all potential old link before doing recursive Remove-Item
        unlink_persist_data (installed_manifest $app $version $global) $dir
        Remove-Item $dir -ErrorAction Stop -Recurse -Force
    }
    $leftVersions = Get-ChildItem $appDir
    if ($leftVersions.Length -eq 1 -and $leftVersions.Name -eq 'current' -and $leftVersions.LinkType) {
        attrib $leftVersions.FullName -R /L
        Remove-Item $leftVersions.FullName -ErrorAction Stop -Force
        $leftVersions = $null
    }
    if (!$leftVersions) {
        Remove-Item $appDir -ErrorAction Stop -Force
    }
    Write-Host ''
}
