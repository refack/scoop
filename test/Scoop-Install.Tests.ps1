BeforeAll {
    . "$PSScriptRoot\Scoop-TestLib.ps1"
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\system.ps1"
    . "$PSScriptRoot\..\lib\manifest.ps1"
    . "$PSScriptRoot\..\lib\install.ps1"
}

Describe 'appname_from_url' -Tag 'Scoop' {
    It 'should extract the correct name' {
        appname_from_url 'https://example.org/directory/foobar.json' | Should -Be 'foobar'
    }
}

Describe 'env add and remove path' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        # test data
        $manifest = @{
            'env_add_path' = @('foo', 'bar', '.', '..')
        }
        $testdir = Join-Path $PSScriptRoot 'path-test-directory'
        $global = $false
    }

    It 'should concat the correct path' {
        Mock Add-Path {}
        Mock Remove-Path {}

        # adding
        env_add_path $manifest $testdir $global
        Should -Invoke -CommandName Add-Path -Times 1 -ParameterFilter { $Path -like "$testdir\foo" }
        Should -Invoke -CommandName Add-Path -Times 1 -ParameterFilter { $Path -like "$testdir\bar" }
        Should -Invoke -CommandName Add-Path -Times 1 -ParameterFilter { $Path -like $testdir }
        Should -Invoke -CommandName Add-Path -Times 0 -ParameterFilter { $Path -like $PSScriptRoot }

        env_rm_path $manifest $testdir $global
        Should -Invoke -CommandName Remove-Path -Times 1 -ParameterFilter { $Path -like "$testdir\foo" }
        Should -Invoke -CommandName Remove-Path -Times 1 -ParameterFilter { $Path -like "$testdir\bar" }
        Should -Invoke -CommandName Remove-Path -Times 1 -ParameterFilter { $Path -like $testdir }
        Should -Invoke -CommandName Remove-Path -Times 0 -ParameterFilter { $Path -like $PSScriptRoot }
    }
}

Describe 'shim_def' -Tag 'Scoop' {
    It 'should use strings correctly' {
        $target, $name, $shimArgs = shim_def 'command.exe'
        $target | Should -Be 'command.exe'
        $name | Should -Be 'command'
        $shimArgs | Should -BeNullOrEmpty
    }

    It 'should expand the array correctly' {
        $target, $name, $shimArgs = shim_def @('foo.exe', 'bar')
        $target | Should -Be 'foo.exe'
        $name | Should -Be 'bar'
        $shimArgs | Should -BeNullOrEmpty

        $target, $name, $shimArgs = shim_def @('foo.exe', 'bar', '--test')
        $target | Should -Be 'foo.exe'
        $name | Should -Be 'bar'
        $shimArgs | Should -Be '--test'
    }
}

Describe 'create_shims bin handling' -Tag 'Scoop' {
    BeforeAll {
        # Mirrors the pipeline in create_shims. The shape matters: binding an
        # intermediate pipeline result to a variable re-flattens nested entries and
        # would hide exactly the regression these tests guard against.
        function Get-ShimDef($manifest, $arch) {
            @(arch_specific 'bin' $manifest $arch) | Where-Object { $_ -ne $null } | ForEach-Object {
                $target, $name, $shimArgs = shim_def $_
                [PSCustomObject]@{ Target = $target; Name = $name; Args = $shimArgs }
            }
        }
    }

    It 'creates one shim per nested entry' {
        $m = '{ "architecture": { "64bit": { "bin": [["UX\\AutohotkeyUX.exe", "autohotkey"], ["v2\\AutoHotkey32.exe", "autohotkey32"]] } } }' | ConvertFrom-Json
        $defs = @(Get-ShimDef $m '64bit')
        $defs.Count | Should -Be 2
        $defs[0].Target | Should -Be 'UX\AutohotkeyUX.exe'
        $defs[0].Name | Should -Be 'autohotkey'
        $defs[1].Target | Should -Be 'v2\AutoHotkey32.exe'
        $defs[1].Name | Should -Be 'autohotkey32'
    }

    It 'handles a single nested entry with arguments' {
        $m = '{ "bin": [["python.exe", "python3", "-3"]] }' | ConvertFrom-Json
        $defs = @(Get-ShimDef $m '64bit')
        $defs.Count | Should -Be 1
        $defs[0].Target | Should -Be 'python.exe'
        $defs[0].Name | Should -Be 'python3'
        $defs[0].Args | Should -Be '-3'
    }

    It 'derives the name for plain string entries' {
        $defs = @(Get-ShimDef ('{ "bin": "foo.exe" }' | ConvertFrom-Json) '64bit')
        $defs.Count | Should -Be 1
        $defs[0].Target | Should -Be 'foo.exe'
        $defs[0].Name | Should -Be 'foo'
        $defs[0].Args | Should -BeNullOrEmpty

        $defs = @(Get-ShimDef ('{ "bin": ["foo.exe", "bar.cmd"] }' | ConvertFrom-Json) '64bit')
        $defs.Count | Should -Be 2
        $defs[0].Name | Should -Be 'foo'
        $defs[1].Name | Should -Be 'bar'
    }

    It 'mixes string and nested entries' {
        $m = '{ "bin": ["plain.exe", ["nested.exe", "aliased"]] }' | ConvertFrom-Json
        $defs = @(Get-ShimDef $m '64bit')
        $defs.Count | Should -Be 2
        $defs[0].Name | Should -Be 'plain'
        $defs[1].Target | Should -Be 'nested.exe'
        $defs[1].Name | Should -Be 'aliased'
    }

    It 'creates no shims when bin is absent' {
        @(Get-ShimDef ('{ "version": "1" }' | ConvertFrom-Json) '64bit').Count | Should -Be 0
    }
}

Describe 'persist_def' -Tag 'Scoop' {
    It 'parses string correctly' {
        $source, $target = persist_def 'test'
        $source | Should -Be 'test'
        $target | Should -Be 'test'
    }

    It 'should handle sub-folder' {
        $source, $target = persist_def 'foo/bar'
        $source | Should -Be 'foo/bar'
        $target | Should -Be 'foo/bar'
    }

    It 'should handle arrays' {
        # both specified
        $source, $target = persist_def @('foo', 'bar')
        $source | Should -Be 'foo'
        $target | Should -Be 'bar'

        # only first specified
        $source, $target = persist_def @('foo')
        $source | Should -Be 'foo'
        $target | Should -Be 'foo'

        # null value specified
        $source, $target = persist_def @('foo', $null)
        $source | Should -Be 'foo'
        $target | Should -Be 'foo'
    }
}
