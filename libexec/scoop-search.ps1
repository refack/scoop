# Usage: scoop search <query>
# Summary: Search available apps
# Help: Searches for apps that are available to install.
#
# If used with [query], shows app names that match the query.
#   - With 'use_sqlite_cache' enabled, [query] is partially matched against app names, binaries, and shortcuts.
#   - Without 'use_sqlite_cache', [query] can be a regular expression to match against app names and binaries.
# Without [query], shows all the available apps.
param($query)

. "$PSScriptRoot\..\lib\manifest.ps1" # 'manifest'
. "$PSScriptRoot\..\lib\versions.ps1" # 'Get-LatestVersion'
. "$PSScriptRoot\..\lib\download.ps1"

$list = @()

function bin_match($manifest, $query) {
    if (!$manifest.bin) { return $false }
    $bins = foreach ($bin in $manifest.bin) {
        $exe, $alias, $args = $bin
        $fname = Split-Path $exe -Leaf -ErrorAction Stop

        if ((strip_ext $fname) -match $query) { $fname }
        elseif ($alias -match $query) { $alias }
    }

    if ($bins) { return $bins }
    else { return $false }
}

function search_app {
    param(
        [Parameter(ValueFromPipeline)]
        $ManifestPathinfo,

        [Parameter()]
        $query
    )

    begin {
        $found = @()
    }

    process {
        $content = [System.IO.File]::ReadAllText($ManifestPathinfo.FullName)
        if ($content -notmatch $query) { return }
        $manifest = ConvertFrom-Json $content -ErrorAction Continue
        $name = [string]$ManifestPathinfo.BaseName
        $bucket = [string]$ManifestPathinfo.Bucket

        if ($name -match $query) {
            # Mathced app name
            $bins = ''
        } elseif ($hits = bin_match $manifest $query) {
            # we consider the binaries as possible hits
            $bins = $hits -join ' | '
        } else {
            return
        }

        $Description = gpod $manifest 'description'
        $Version = gpod $manifest 'version'
#        # Too much will make the output default to Format-List
#        if ($desc.Length -gt 40) {
#            $desc = $desc.Substring(0, 37) + "..."
#        }

        $found += [PSCustomObject]@{
            PSTypeName = 'Scoop.SearchHit'
            Name = $name
            Version = $Version
            Source = $bucket
            Binaries = $bins
            Description = $Description
        }
    }

    end {
        $found | ? { $_ }
    }
}

function search_remote($bucket, $query) {
    $uri = [System.Uri](known_bucket_repo $bucket)
    if ($uri.AbsolutePath -match '/([a-zA-Z0-9]*)/([a-zA-Z0-9-]*)(?:.git|/)?') {
        $user = $Matches[1]
        $repo_name = $Matches[2]
        $api_link = "https://api.github.com/repos/$user/$repo_name/git/trees/HEAD?recursive=1"
        $result = download_json $api_link | Select-Object -ExpandProperty tree |
            Where-Object -Value "^bucket/(.*$query.*)\.json$" -Property Path -Match |
            ForEach-Object { $Matches[1] }
    }

    $result
}

function search_remotes($query) {
    $buckets = known_bucket_repos
    $names = $buckets | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty name

    $results = $names | Where-Object { !(Test-Path $(Find-BucketDirectory $_)) } | ForEach-Object {
        @{ 'bucket' = $_; 'results' = (search_remote $_ $query) }
    } | Where-Object { $_.results }

    if ($results.count -gt 0) {
        Write-Host "Results from other known buckets...`n(add them using 'scoop bucket add <bucket name>')"
    }

    $remote_list = @()
    $results | ForEach-Object {
        $bucket = $_.bucket
        $_.results | ForEach-Object {
            $item = [ordered]@{}
            $item.Name = $_
            $item.Source = $bucket
            $remote_list += [PSCustomObject]$item
        }
    }
    $remote_list
}

function get_local_manifests {
    param(
        [Parameter(ValueFromPipeline)]
        [IO.FileInfo]
        $bucket
    )

    begin {
        $all = @()

    }

    process {
        $all += Get-ChildItem (Find-BucketDirectory $bucket) -Filter '*.json' -Recurse |
            Select-Object FullName, BaseName, @{Name='Bucket'; Expression={$bucket}}
    }

    end {
        return $all
    }
}

################### Main ##########################

Update-TypeData -Force -TypeName 'Scoop.SearchHit' -DefaultDisplayPropertySet @('Name', 'Source', 'Version', 'Description')

if (get_config USE_SQLITE_CACHE) {
    . "$PSScriptRoot\..\lib\database.ps1"
    Find-ScoopDBItem $query -From @('name', 'binary', 'shortcut') |
        Select-Object -Property name, version, bucket, binary |
        ForEach-Object {
            $list.Add([PSCustomObject]@{
                    Name     = $_.name
                    Version  = $_.version
                    Source   = $_.bucket
                    Binaries = $_.binary
                })
        }
} else {
    try {
        $query = New-Object Regex $query, 'IgnoreCase'
    } catch {
        abort "Invalid regular expression: $($_.Exception.InnerException.Message)"
    }

    $all = Get-LocalBucket | get_local_manifests
    $list = $all | search_app -query $query
}

if ($list.Count -gt 0) {
    Write-Host 'Results from local buckets...'
    $list
}

if ($list.Count -eq 0 -and !(github_ratelimit_reached)) {
    $remote_results = search_remotes $query
    if (!$remote_results) {
        warn 'No hits found.'
        exit 1
    }
    $remote_results
}

exit 0
