BeforeAll {
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\json.ps1"
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\manifest.ps1"
    . "$PSScriptRoot\..\lib\buckets.ps1"
    . "$PSScriptRoot\..\lib\database.ps1"
    . "$PSScriptRoot\..\lib\autoupdate.ps1"
}

Describe 'JSON parse and beautify' -Tag 'Scoop' {
    Context 'Parse JSON' {
        It 'success with valid json' {
            { parse_json "$PSScriptRoot\fixtures\manifest\wget.json" } | Should -Not -Throw
            $parsed = parse_json "$PSScriptRoot\fixtures\manifest\wget.json"
            $parsed | Should -Not -Be $null
        }
        It 'returns null and warns with invalid json' {
            Mock warn {}
            { parse_json "$PSScriptRoot\fixtures\manifest\broken_wget.json" } | Should -Not -Throw
            $parsed = parse_json "$PSScriptRoot\fixtures\manifest\broken_wget.json"
            $parsed | Should -Be $null
            Should -Invoke -CommandName warn -Times 1
        }
    }
    Context 'Beautify JSON' {
        BeforeDiscovery {
            $manifests = (Get-ChildItem "$PSScriptRoot\fixtures\format\formatted" -File -Filter '*.json').Name
        }
        BeforeAll {
            $format = "$PSScriptRoot\fixtures\format"
        }
        It '<_>' -ForEach $manifests {
            $pretty_json = (parse_json "$format\unformatted\$_") | ConvertToPrettyJson
            $correct = (Get-Content "$format\formatted\$_") -join "`r`n"
            $correct.CompareTo($pretty_json) | Should -Be 0
        }
    }
}

Describe 'arch_specific' -Tag 'Scoop' {
    BeforeAll {
        # real manifests reach arch_specific as PSCustomObject (via parse_json), which is
        # the shape that regressed - hashtable literals do not exercise the same path
        $nested = '{ "architecture": { "64bit": { "bin": [["UX\\AutohotkeyUX.exe", "autohotkey"], ["v2\\AutoHotkey32.exe", "autohotkey32"]] } } }' | ConvertFrom-Json
        $singleNested = '{ "bin": [["AppData\\010Editor.exe", "010editor"]] }' | ConvertFrom-Json
        $override = '{ "bin": "generic.exe", "architecture": { "64bit": { "bin": "specific.exe" } } }' | ConvertFrom-Json
        $noBin = '{ "architecture": { "64bit": { "url": "http://example.org/f.zip" } } }' | ConvertFrom-Json
        # hwinfo shape: url/hash live at the root, the arch block only refines bin/shortcuts
        $partialArch = '{ "url": "http://root/f.zip", "hash": "abc", "architecture": { "64bit": { "bin": "b.exe" } } }' | ConvertFrom-Json
    }

    It 'preserves a list of nested entries' {
        # regression: the outer array was unrolled on return, collapsing every entry into one
        $bin = @(arch_specific 'bin' $nested '64bit')
        $bin.Count | Should -Be 2
        ($bin[0] -join '|') | Should -Be 'UX\AutohotkeyUX.exe|autohotkey'
        ($bin[1] -join '|') | Should -Be 'v2\AutoHotkey32.exe|autohotkey32'
    }

    It 'preserves a single nested entry' {
        $bin = @(arch_specific 'bin' $singleNested '64bit')
        $bin.Count | Should -Be 1
        ($bin[0] -join '|') | Should -Be 'AppData\010Editor.exe|010editor'
    }

    It 'prefers the architecture-specific value and falls back to the root' {
        arch_specific 'bin' $override '64bit' | Should -Be 'specific.exe'
        arch_specific 'bin' $override '32bit' | Should -Be 'generic.exe'
        arch_specific 'bin' $singleNested '64bit' | Should -Not -BeNullOrEmpty
    }

    It 'falls back to the root when the arch block omits the property' {
        # regression: an arch block present but silent about 'url'/'hash' shadowed the
        # root ones, so downloads got a null url (hwinfo, and many other manifests)
        arch_specific 'url' $partialArch '64bit' | Should -Be 'http://root/f.zip'
        arch_specific 'hash' $partialArch '64bit' | Should -Be 'abc'
        arch_specific 'bin' $partialArch '64bit' | Should -Be 'b.exe'
    }

    It 'emits nothing when the property is absent' {
        # regression: emitting $null made `@(...)` a one-element array holding $null,
        # so callers iterated once over nothing (see url_filename)
        @(arch_specific 'bin' $noBin '64bit').Count | Should -Be 0
        @(arch_specific 'bin' ('{ "version": "1" }' | ConvertFrom-Json) '64bit').Count | Should -Be 0
        arch_specific 'bin' $noBin '64bit' | Should -BeNullOrEmpty
    }

    It 'keeps a multi-value url intact' {
        $m = '{ "architecture": { "64bit": { "url": ["http://a/f.zip", "http://b/g.zip"] } } }' | ConvertFrom-Json
        $urls = @(arch_specific 'url' $m '64bit')
        $urls.Count | Should -Be 2
        $urls[1] | Should -Be 'http://b/g.zip'
    }

    It 'handles a hashtable manifest and a null architecture' {
        # env_add_path/env_rm_path call arch_specific without an architecture
        $m = @{ 'env_add_path' = @('foo', 'bar') }
        $paths = @(arch_specific 'env_add_path' $m $null)
        $paths.Count | Should -Be 2
        ($paths -join '|') | Should -Be 'foo|bar'
    }
}

Describe 'Handle ARM64 and correctly fallback' -Tag 'Scoop' {
    It 'Should return "arm64" if supported' {
        $manifest1 = @{ url = 'test'; architecture = @{ 'arm64' = @{ pre_install = 'test' } } }
        $manifest2 = @{ url = 'test'; pre_install = "'arm64'" }
        $manifest3 = @{ architecture = @{ 'arm64' = @{ url = 'test' } } }
        Get-SupportedArchitecture $manifest1 'arm64' | Should -Be 'arm64'
        Get-SupportedArchitecture $manifest2 'arm64' | Should -Be 'arm64'
        Get-SupportedArchitecture $manifest3 'arm64' | Should -Be 'arm64'
    }
    It 'Should return "64bit" if unsupported on Windows 11' {
        $WindowsBuild = 22000
        $manifest1 = @{ url = 'test' }
        $manifest2 = @{ architecture = @{ '64bit' = @{ url = 'test' } } }
        Get-SupportedArchitecture $manifest1 'arm64' | Should -Be '64bit'
        Get-SupportedArchitecture $manifest2 'arm64' | Should -Be '64bit'
    }
    It 'Should return "32bit" if unsupported on Windows 10' {
        $WindowsBuild = 19044
        $manifest2 = @{ url = 'test' }
        $manifest1 = @{ url = 'test'; architecture = @{ '64bit' = @{ pre_install = 'test' } } }
        $manifest3 = @{ architecture = @{ '64bit' = @{ url = 'test' } } }
        Get-SupportedArchitecture $manifest1 'arm64' | Should -Be '32bit'
        Get-SupportedArchitecture $manifest2 'arm64' | Should -Be '32bit'
        Get-SupportedArchitecture $manifest3 'arm64' | Should -BeNullOrEmpty
    }
}

Describe 'arch_specific truthiness (documents latent hazard in strict-safe lookup)' -Tag 'Scoop' {
    # These encode vanilla semantics: a *present* arch-specific prop wins, even when falsy.
    # The patched arch_specific tests `if (!$the_obj)`, so @() / '' are treated as absent
    # and fall back to the top-level prop. No manifest in the installed buckets currently
    # does this (scan 2026-08-20: 0/3596), so failures here are latent, not live.
    It 'empty arch-specific bin overrides top-level bin' {
        $m = '{ "bin": "top.exe", "architecture": { "64bit": { "bin": [] } } }' | ConvertFrom-Json
        @(arch_specific 'bin' $m '64bit') | Should -BeNullOrEmpty
    }
    It 'empty-string arch-specific pre_install overrides top-level' {
        $m = '{ "pre_install": "top", "architecture": { "64bit": { "pre_install": "" } } }' | ConvertFrom-Json
        arch_specific 'pre_install' $m '64bit' | Should -Be ''
    }
    It 'Get-NestedProp tolerates a falsy root object under StrictMode' {
        # `if ($Object) { $MaybeObject = $Object }` leaves $MaybeObject unassigned for
        # falsy roots (@(), 0, ''), which StrictMode turns into a throw inside the loop.
        { & { Set-StrictMode -Version Latest; Get-NestedProp @() @('bin') } } | Should -Not -Throw
    }
}

Describe 'Manifest Validator' -Tag 'Validator' {
    # Could not use backslash '\' in Linux/macOS for .NET object 'Scoop.Validator'
    BeforeAll {
        Add-Type -Path "$PSScriptRoot\..\supporting\validator\bin\Scoop.Validator.dll"
        $schema = "$PSScriptRoot/../schema.json"
    }

    It 'Scoop.Validator is available' {
            ([System.Management.Automation.PSTypeName]'Scoop.Validator').Type | Should -Be 'Scoop.Validator'
    }
    It 'fails with broken schema' {
        $validator = New-Object Scoop.Validator("$PSScriptRoot/fixtures/manifest/broken_schema.json", $true)
        $validator.Validate("$PSScriptRoot/fixtures/manifest/wget.json") | Should -BeFalse
        $validator.Errors.Count | Should -Be 1
        $validator.Errors | Select-Object -First 1 | Should -Match 'broken_schema.*(line 6).*(position 4)'
    }
    It 'fails with broken manifest' {
        $validator = New-Object Scoop.Validator($schema, $true)
        $validator.Validate("$PSScriptRoot/fixtures/manifest/broken_wget.json") | Should -BeFalse
        $validator.Errors.Count | Should -Be 1
        $validator.Errors | Select-Object -First 1 | Should -Match 'broken_wget.*(line 5).*(position 4)'
    }
    It 'fails with invalid manifest' {
        $validator = New-Object Scoop.Validator($schema, $true)
        $validator.Validate("$PSScriptRoot/fixtures/manifest/invalid_wget.json") | Should -BeFalse
        $validator.Errors.Count | Should -Be 16
        $validator.Errors | Select-Object -First 1 | Should -Match "Property 'randomproperty' has not been defined and the schema does not allow additional properties\."
        $validator.Errors | Select-Object -Last 1 | Should -Match 'Required properties are missing from object: version\.'
    }
}

Describe 'Find-HistoricalManifestInCache' -Tag 'Scoop' {
    It 'returns $null when sqlite cache disabled' {
        Mock get_config -ParameterFilter { $name -eq 'use_sqlite_cache' } { $false }
        $result = Find-HistoricalManifestInCache 'foo' 'main' '1.0.0'
        $result | Should -Be $null
    }

    It 'returns manifest text and version when cache has exact match' {
        $tempUM = Join-Path $env:TEMP 'ScoopTestsUM'
        Mock get_config -ParameterFilter { $name -in @('use_sqlite_cache','use_git_history') } { $true }
        Mock Get-ScoopDBItem {
            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('manifest')
            $row = $dt.NewRow()
            $row['manifest'] = '{"version":"1.2.3"}'
            [void]$dt.Rows.Add($row)
            Write-Output $dt -NoEnumerate
        }
        Mock ensure {}
        $result = Find-HistoricalManifestInCache 'foo' 'main' '1.2.3'
        $result | Should -Not -BeNullOrEmpty
        $result.version | Should -Be '1.2.3'
        $result.ManifestText | Should -Match '"version":"1.2.3"'
    }
}

Describe 'Find-HistoricalManifestInGit' -Tag 'Scoop' {
    BeforeEach {
        $bucketRoot = 'C:\b\root'
        $innerBucket = 'C:\b\root\bucket'
        Mock get_config -ParameterFilter { $name -eq 'use_git_history' } { $true }
        Mock Find-BucketDirectory -ParameterFilter { $Root } { $bucketRoot }
        Mock Find-BucketDirectory -ParameterFilter { -not $Root } { $innerBucket }
        Mock Test-Path -ParameterFilter { $Path -eq (Join-Path $bucketRoot '.git') } { $true }
        Mock Test-Path -ParameterFilter { $Path -eq $innerBucket -and $PathType -eq 'Container' } { $true }
    }

    It 'returns $null when git history search disabled' {
        Mock get_config -ParameterFilter { $name -eq 'use_git_history' } { $false }
        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should -Be $null
    }

    It 'returns manifest text on version match' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"2.0.0"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' } { return '{"version":"1.0.0"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' } { @('abcdef0123456789') }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should -Not -BeNullOrEmpty
        $result.version | Should -Be '1.0.0'
        $result.ManifestText | Should -Match '"version":"1.0.0"'
    }

    It 'short-circuits via HEAD fast-path when HEAD already has the requested version' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"1.0.0"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' } { @('shouldnotbeused') }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should -Not -BeNullOrEmpty
        $result.version | Should -Be '1.0.0'
        $result.source | Should -Be 'git_manifest:HEAD'
        Should -Invoke -CommandName Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' } -Times 0
    }

    It 'falls back to -S pickaxe when -G yields no commits' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"2.0.0"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' -and $ArgumentList -contains '-G' } { return @() }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' -and $ArgumentList -contains '-S' } { return @('feedface') }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -notlike 'HEAD*' } { return '{"version":"1.0.0"}' }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should -Not -BeNullOrEmpty
        $result.version | Should -Be '1.0.0'
        $result.source | Should -Be 'git_manifest:feedface^'
    }

    It 'returns $null when $h / $h^ walk yields no manifest' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"9.9.9"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -match '^[a-f0-9]+\^?:' } { return '{"version":"9.9.9"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' -and $ArgumentList -contains '-n' } { return @('aaaa1111') }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should -Be $null
    }

    It 'returns $null when inner bucket directory cannot be found' {
        Mock Test-Path -ParameterFilter { $Path -eq $innerBucket -and $PathType -eq 'Container' } { $false }
        Mock warn {}
        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should -Be $null
    }
}

Describe 'Find-HistoricalManifest (orchestrator)' -Tag 'Scoop' {
    It 'returns $null when both cache and git miss' {
        Mock get_config -ParameterFilter { $name -in @('use_sqlite_cache','use_git_history') } { $true }
        Mock Find-HistoricalManifestInCache { $null }
        Mock Find-HistoricalManifestInGit { $null }
        $result = Find-HistoricalManifest 'foo' 'main' '1.0.0'
        $result | Should -Be $null
    }
}

Describe 'Write-ManifestToUserCache' -Tag 'Scoop' {
    It 'writes to $App.json (no version suffix) so downstream install path does not duplicate version' {
        $umdir = Join-Path $env:TEMP ("ScoopUM_" + [guid]::NewGuid().ToString('N'))
        Mock usermanifestsdir { $umdir }
        $p = Write-ManifestToUserCache -App 'foo' -ManifestText '{"version":"1.0.0"}'
        $p | Should -Be (Join-Path $umdir 'foo.json')
        Test-Path $p | Should -Be $true
        Remove-Item -Recurse -Force $umdir -ErrorAction SilentlyContinue
    }
}

Describe 'generate_user_manifest (history-aware)' -Tag 'Scoop' {
    It 'returns manifest_path when versions match' {
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version='1.0.0' }, 'main', $null }
        Mock manifest_path { 'C:\path\foo.json' }
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should -Be 'C:\path\foo.json'
    }

    It 'prefers history orchestrator hit (cache) when enabled' {
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version='2.0.0' }, 'main', $null }
        Mock get_config -ParameterFilter { $name -in @('use_sqlite_cache','use_git_history') } { $true }
        Mock Find-HistoricalManifest { @{ path = 'C:\cache\foo.json'; version = '1.0.0'; source='sqlite_exact_match' } }

        Mock info {}
        Mock warn {}
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should -Be 'C:\cache\foo.json'
        Should -Invoke -CommandName Find-HistoricalManifest -Times 1

    }

    It 'falls back to git history when cache misses' {
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version='2.0.0' }, 'main', $null }
        Mock get_config -ParameterFilter { $name -in @('use_sqlite_cache','use_git_history') } { $true }
        Mock Find-HistoricalManifest { @{ path = 'C:\git\foo.json'; version = '1.0.0'; source='git_manifest:hash' } }
        Mock info {}
        Mock warn {}
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should -Be 'C:\git\foo.json'
        Should -Invoke -CommandName Find-HistoricalManifest -Times 1

    }

    It 'uses autoupdate when no history found and autoupdate exists' {
        $umdir = Join-Path $env:TEMP 'ScoopTestsUM'
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version='2.0.0'; autoupdate=@{} }, 'main', $null }
        Mock get_config -ParameterFilter { $name -eq 'use_sqlite_cache' } { $false }
        Mock Find-HistoricalManifest { $null }

        Mock ensure {}
        Mock usermanifestsdir { $umdir }
        Mock Invoke-AutoUpdate {}
        Mock warn {}
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should -Be (Join-Path $umdir 'foo.json')
        Should -Invoke -CommandName warn -Times 1 -ParameterFilter { $msg -match "No historical manifest found for 'foo@1\.0\.0'; attempting autoupdate" }
    }

    It 'returns $null when autoupdate fails (caller surfaces the error)' {
        $umdir = Join-Path $env:TEMP 'ScoopTestsUM'
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version='2.0.0'; autoupdate=@{} }, 'main', $null }
        Mock get_config -ParameterFilter { $name -eq 'use_sqlite_cache' } { $false }
        Mock Find-HistoricalManifest { $null }
        Mock ensure {}
        Mock usermanifestsdir { $umdir }
        Mock Invoke-AutoUpdate { throw 'fail' }
        Mock warn {}
        Mock info {}
        Mock abort { throw 'aborted' }
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should -Be $null
        Should -Invoke -CommandName abort -Times 0
    }

    It 'aborts when no history and no autoupdate' {
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version='2.0.0' }, 'main', $null }
        Mock get_config -ParameterFilter { $name -eq 'use_sqlite_cache' } { $false }
        Mock Find-HistoricalManifest { $null }

        Mock warn {}
        Mock info {}
        Mock abort { throw 'aborted' }
        { generate_user_manifest 'foo' 'main' '1.0.0' } | Should -Throw
    }
}

