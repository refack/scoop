# Usage: scoop cleanup <app> [options]
# Summary: Cleanup apps by removing old versions
# Help: 'scoop cleanup' cleans Scoop apps by removing old versions.
# 'scoop cleanup <app>' cleans up the old versions of that app if said versions exist.
#
# You can use '*' in place of <app> or `-a`/`--all` switch to cleanup all apps.
#
# Options:
#   -a, --all          Cleanup all apps (alternative to '*')
#   -g, --global       Cleanup a globally installed app
#   -k, --cache        Remove outdated download cache

. "$PSScriptRoot\..\lib\getopt.ps1"
. "$PSScriptRoot\..\lib\manifest.ps1" # 'Select-CurrentVersion' (indirectly)
. "$PSScriptRoot\..\lib\versions.ps1" # 'Select-CurrentVersion'
. "$PSScriptRoot\..\lib\install.ps1" # persist related
. "$PSScriptRoot\..\lib\cleanup.ps1" # 'cleanup'

$opt, $apps, $err = getopt $args 'agk' 'all', 'global', 'cache'
if ($err) { error "scoop cleanup: $err"; exit 1 }
$global = $opt.g -or $opt.global
$cache = $opt.k -or $opt.cache
$all = $opt.a -or $opt.all
$failed = @{}

if (!$apps -and !$all) { error '<app> missing'; my_usage; exit 1 }

if ($global -and !(is_admin)) {
    error 'you need admin rights to cleanup global apps'; exit 1
}

if ($apps -or $all) {
    if ($apps -eq '*' -or $all) {
        $verbose = $false
        $apps = applist (installed_apps $false) $false
        if ($global) {
            $apps += applist (installed_apps $true) $true
        }
    } else {
        $verbose = $true
        $install_status = Confirm-InstallationStatus $apps -Global:$global
        $apps = $install_status.installed
        $install_status.failed.Keys | Where-Object { $install_status.failed[$_] -eq 'not installed in the requested scope' } | ForEach-Object { $failed[$_] = $install_status.failed[$_] }
    }

    # $apps is now a list of ($app, $global) tuples
    $apps | ForEach-Object { cleanup @_ $verbose $cache }

    if ($cache) {
        Remove-Item "$cachedir\*.download" -ErrorAction Ignore
    }

    if (!$verbose) {
        success 'Everything is shiny now!'
    }
}

$failed_count = show_failed_apps $failed 'cleanup'

exit [int]($failed_count -gt 0)
