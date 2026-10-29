BeforeAll {
    . "$PSScriptRoot\Scoop-TestLib.ps1"
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\system.ps1"
    . "$PSScriptRoot\..\lib\shim.ps1"
    . "$PSScriptRoot\..\lib\install.ps1"
}

Describe 'Get-AppFilePath' -Tag 'Scoop' {
    BeforeAll {
        $working_dir = setup_working 'is_directory'
        Mock currentdir { 'local' } -Verifiable -ParameterFilter { $global -eq $false }
        Mock currentdir { 'global' } -Verifiable -ParameterFilter { $global -eq $true }
    }

    It 'should return locally installed program' {
        Mock Test-Path { $true } -Verifiable -ParameterFilter { $Path -eq 'local\i_am_a_file.txt' }
        Mock Test-Path { $false } -Verifiable -ParameterFilter { $Path -eq 'global\i_am_a_file.txt' }
        Get-AppFilePath -App 'is_directory' -File 'i_am_a_file.txt' | Should-Be 'local\i_am_a_file.txt'
    }

    It 'should return globally installed program' {
        Mock Test-Path { $false } -Verifiable -ParameterFilter { $Path -eq 'local\i_am_a_file.txt' }
        Mock Test-Path { $true } -Verifiable -ParameterFilter { $Path -eq 'global\i_am_a_file.txt' }
        Get-AppFilePath -App 'is_directory' -File 'i_am_a_file.txt' | Should-Be 'global\i_am_a_file.txt'
    }

    It 'should return null if program is not installed' {
        Get-AppFilePath -App 'is_directory' -File 'i_do_not_exist' | Should-BeNull
    }

    It 'should throw if parameter is wrong or missing' {
        { Get-AppFilePath -App 'is_directory' -File } | Should-Throw
        { Get-AppFilePath -App -File 'i_am_a_file.txt' } | Should-Throw
        { Get-AppFilePath -App -File } | Should-Throw
    }
}

Describe 'Get-HelperPath' -Tag 'Scoop' {
    BeforeAll {
        $working_dir = setup_working 'is_directory'
    }
    It 'should return path if program is installed' {
        Mock Get-AppFilePath { '7zip\current\7z.exe' }
        Get-HelperPath -Helper 7zip | Should-Be '7zip\current\7z.exe'
    }

    It 'should return null if program is not installed' {
        Mock Get-AppFilePath { $null }
        Get-HelperPath -Helper 7zip | Should-BeNull
    }

    It 'should throw if parameter is wrong or missing' {
        { Get-HelperPath -Helper } | Should-Throw
        { Get-HelperPath -Helper Wrong } | Should-Throw
    }

    Context 'Git' {
        BeforeEach {
            $gitTestRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
            Mock currentdir { "$gitTestRoot\git" }
            Mock Get-Command { [PSCustomObject]@{ Source = 'path\git.exe' } } -ParameterFilter { $Name -eq 'git' }
        }

        It 'should prefer cmd\git.exe over runtime executables' {
            foreach ($dir in 'cmd', 'mingw32\bin', 'mingw64\bin', 'ucrt64\bin', 'clangarm64\bin') {
                $null = New-Item -ItemType Directory -Path "$gitTestRoot\git\$dir" -Force
                $null = New-Item -ItemType File -Path "$gitTestRoot\git\$dir\git.exe"
            }

            $git = Get-HelperPath -Helper Git
            $git | Should-Be "$gitTestRoot\git\cmd\git.exe"
            @($git) | Should-BeCollection -Count 1
        }

        It 'should fall back to Git on PATH when it is not installed by Scoop' {
            Get-HelperPath -Helper Git | Should-Be 'path\git.exe'
        }
    }
}


Describe 'Test-HelperInstalled' -Tag 'Scoop' {
    It 'should return true if program is installed' {
        Mock Get-HelperPath { '7z.exe' }
        Test-HelperInstalled -Helper 7zip | Should-BeTrue
    }

    It 'should return false if program is not installed' {
        Mock Get-HelperPath { $null }
        Test-HelperInstalled -Helper 7zip | Should-BeFalse
    }

    It 'should throw if parameter is wrong or missing' {
        { Test-HelperInstalled -Helper } | Should-Throw
        { Test-HelperInstalled -Helper Wrong } | Should-Throw
    }
}

Describe 'Test-CommandAvailable' -Tag 'Scoop' {
    It 'should return true if command exists' {
        Test-CommandAvailable 'Write-Host' | Should-BeTrue
    }

    It "should return false if command doesn't exist" {
        Test-CommandAvailable 'Write-ThisWillProbablyNotExist' | Should-BeFalse
    }

    It 'should throw if parameter is wrong or missing' {
        { Test-CommandAvailable } | Should-Throw
    }
}


Describe 'Confirm-InstallationStatus' -Tag 'Scoop' {
    It 'should report apps that are not installed' {
        Mock error {}

        $status = Confirm-InstallationStatus 'not_installed_app_xyz'

        $status.installed | Should-BeCollection -Count 0
        $status.failed['not_installed_app_xyz'] | Should-Be 'not installed'
    }
}


Describe 'is_directory' -Tag 'Scoop' {
    BeforeAll {
        $working_dir = setup_working 'is_directory'
    }

    It 'is_directory recognize directories' {
        is_directory "$working_dir\i_am_a_directory" | Should-Be $true
    }
    It 'is_directory recognize files' {
        is_directory "$working_dir\i_am_a_file.txt" | Should-Be $false
    }

    It 'is_directory is falsey on unknown path' {
        is_directory "$working_dir\i_do_not_exist" | Should-Be $false
    }
}

Describe 'movedir' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        $working_dir = setup_working 'movedir'
        $extract_dir = 'subdir'
        $extract_to = $null
    }

    It 'moves directories with no spaces in path' {
        $dir = "$working_dir\user"
        movedir "$dir\_tmp\$extract_dir" "$dir\$extract_to"

        (Get-Content "$dir\test.txt" -Raw) | Should-MatchString 'this is the one'
        Test-Path "$dir\_tmp\$extract_dir" | Should-BeFalse
    }

    It 'moves directories with spaces in path' {
        $dir = "$working_dir\user with space"
        movedir "$dir\_tmp\$extract_dir" "$dir\$extract_to"

        (Get-Content "$dir\test.txt" -Raw) | Should-MatchString 'this is the one'
        Test-Path "$dir\_tmp\$extract_dir" | Should-BeFalse

        # test trailing \ in from dir
        movedir "$dir\_tmp\$null" "$dir\another"
        (Get-Content "$dir\another\test.txt" -Raw) | Should-MatchString 'testing'
        Test-Path "$dir\_tmp" | Should-BeFalse
    }

    It 'moves directories with quotes in path' {
        $dir = "$working_dir\user with 'quote"
        movedir "$dir\_tmp\$extract_dir" "$dir\$extract_to"

        (Get-Content "$dir\test.txt" -Raw) | Should-MatchString 'this is the one'
        Test-Path "$dir\_tmp\$extract_dir" | Should-BeFalse
    }
}

Describe 'cache_path' -Tag 'Scoop' {
    It 'returns the correct cache path for a given input' {
        $url = 'https://example.com/git.zip'
        $ret = cache_path 'git' '2.44.0' $url
        $inputStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($url))
        $sha = (Get-FileHash -Algorithm SHA256 -InputStream $inputStream).Hash.ToLower().Substring(0, 7)
        $ret | Should-Be "$cachedir\git#2.44.0#$sha.zip"
    }

    # # NOTE: Remove this 6 months after the feature ships.
    It 'returns the old format cache path for a given input' {
        Mock Test-Path { $true }
        $ret = cache_path 'git' '2.44.0' 'https://example.com/git.zip'
        $ret | Should-Be "$cachedir\git#2.44.0#https_example.com_git.zip"
    }
}

Describe 'Get-RelativePath' -Tag 'Scoop' {
    It 'returns relative path for child path' {
        $from = 'C:\root\bucket'
        $to = 'C:\root\bucket\foo\bar.json'
        Get-RelativePath $from $to | Should-Be 'foo\bar.json'
    }
    It 'returns original when different drive/scheme' {
        $from = 'C:\root\bucket'
        $to = 'D:\other\file.json'
        Get-RelativePath $from $to | Should-Be $to
    }
    It 'handles paths containing characters that break [System.Uri]' {
        $from = 'C:\b#ucket'
        $to = 'C:\b#ucket\foo.json'
        Get-RelativePath $from $to | Should-Be 'foo.json'
    }
    It 'returns the input when target is not under base' {
        $from = 'C:\root\bucket'
        $to = 'C:\other\foo.json'
        Get-RelativePath $from $to | Should-Be $to
    }
}

Describe 'is_in_dir' -Tag 'Scoop' {
    It 'returns false when path is not under dir' {
        is_in_dir 'C:\test' 'C:\foo' | Should-BeFalse
    }
    It 'returns true when path is under dir' {
        is_in_dir 'C:\test' 'C:\test\foo\baz.zip' | Should-BeTrue
    }
    It 'returns true when dir has a trailing separator' {
        is_in_dir "$PSScriptRoot\..\" "$PSScriptRoot" | Should-BeTrue
    }
    It 'returns false when path escapes dir through dot segments' {
        is_in_dir 'C:\test\sub' 'C:\test\sub\..\..\Windows\notepad.exe' | Should-BeFalse
    }
}

Describe 'Add-Path' -Tag 'Scoop', 'Windows' {
    It 'should expand %VAR% in the current session but keep it in the stored value' {
        Mock Set-EnvVar {}
        $env:COOP_TEST_PATH = 'C:\some\path'
        $before = $env:PATH
        try {
            Add-Path -Path '%COOP_TEST_PATH%' -Force -Quiet

            ($env:PATH -match 'C:\\some\\path') | Should-BeTrue
            Should-Invoke Set-EnvVar -Times 1 -ParameterFilter { $Value -like '*%COOP_TEST_PATH%*' }
        } finally {
            $env:PATH = $before
            Remove-Item env:\COOP_TEST_PATH -ErrorAction SilentlyContinue
        }
    }
}

Describe 'currentdir' -Tag 'Scoop' {
    It 'resolves version directory when NO_JUNCTION is enabled without preloading versions.ps1' {
        Mock get_config { $true } -ParameterFilter { $name -eq 'NO_JUNCTION' }
        Mock appdir { 'C:\scoop\apps\git' }
        $null = & { currentdir 'git' $false }
    }
    It 'returns the junction path when NO_JUNCTION is disabled' {
        Mock get_config { $false } -ParameterFilter { $name -eq 'NO_JUNCTION' }
        Mock appdir { 'C:\scoop\apps\git' }
        currentdir 'git' $false | Should-Be 'C:\scoop\apps\git\current'
    }
    It 'keeps using the junction for scoop itself' {
        Mock get_config { $true } -ParameterFilter { $name -eq 'NO_JUNCTION' }
        Mock appdir { 'C:\scoop\apps\scoop' }
        currentdir 'scoop' $false | Should-Be 'C:\scoop\apps\scoop\current'
    }
}

Describe 'sanitary_path' -Tag 'Scoop' {
    It 'removes invalid path characters from a string' {
        $path = 'test?.json'
        $valid_path = sanitary_path $path

        $valid_path | Should-Be 'test.json'
    }
}

Describe 'app' -Tag 'Scoop' {
    It 'parses the bucket name from an app query' {
        $query = 'C:\test.json'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be 'C:\test.json'
        $bucket | Should-BeNull
        $version | Should-BeNull

        $query = 'test.json'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be 'test.json'
        $bucket | Should-BeNull
        $version | Should-BeNull

        $query = '.\test.json'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be '.\test.json'
        $bucket | Should-BeNull
        $version | Should-BeNull

        $query = '..\test.json'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be '..\test.json'
        $bucket | Should-BeNull
        $version | Should-BeNull

        $query = '\\share\test.json'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be '\\share\test.json'
        $bucket | Should-BeNull
        $version | Should-BeNull

        $query = 'https://example.com/test.json'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be 'https://example.com/test.json'
        $bucket | Should-BeNull
        $version | Should-BeNull

        $query = 'test'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be 'test'
        $bucket | Should-BeNull
        $version | Should-BeNull

        $query = 'extras/enso'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be 'enso'
        $bucket | Should-Be 'extras'
        $version | Should-BeNull

        $query = 'test-app'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be 'test-app'
        $bucket | Should-BeNull
        $version | Should-BeNull

        $query = 'test-bucket/test-app'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be 'test-app'
        $bucket | Should-Be 'test-bucket'
        $version | Should-BeNull

        $query = 'test-bucket/test-app@1.8.0'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be 'test-app'
        $bucket | Should-Be 'test-bucket'
        $version | Should-Be '1.8.0'

        $query = 'test-bucket/test-app@1.8.0-rc2'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be 'test-app'
        $bucket | Should-Be 'test-bucket'
        $version | Should-Be '1.8.0-rc2'

        $query = 'test-bucket/test_app'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be 'test_app'
        $bucket | Should-Be 'test-bucket'
        $version | Should-BeNull

        $query = 'test-bucket/test_app@1.8.0'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be 'test_app'
        $bucket | Should-Be 'test-bucket'
        $version | Should-Be '1.8.0'

        $query = 'test-bucket/test_app@1.8.0-rc2'
        $app, $bucket, $version = parse_app $query
        $app | Should-Be 'test_app'
        $bucket | Should-Be 'test-bucket'
        $version | Should-Be '1.8.0-rc2'
    }
}

Describe 'Format Architecture String' -Tag 'Scoop' {
    It 'should keep correct architectures' {
        Format-ArchitectureString '32bit' | Should-Be '32bit'
        Format-ArchitectureString '32' | Should-Be '32bit'
        Format-ArchitectureString 'x86' | Should-Be '32bit'
        Format-ArchitectureString 'X86' | Should-Be '32bit'
        Format-ArchitectureString 'i386' | Should-Be '32bit'
        Format-ArchitectureString '386' | Should-Be '32bit'
        Format-ArchitectureString 'i686' | Should-Be '32bit'

        Format-ArchitectureString '64bit' | Should-Be '64bit'
        Format-ArchitectureString '64' | Should-Be '64bit'
        Format-ArchitectureString 'x64' | Should-Be '64bit'
        Format-ArchitectureString 'X64' | Should-Be '64bit'
        Format-ArchitectureString 'amd64' | Should-Be '64bit'
        Format-ArchitectureString 'AMD64' | Should-Be '64bit'
        Format-ArchitectureString 'x86_64' | Should-Be '64bit'
        Format-ArchitectureString 'x86-64' | Should-Be '64bit'

        Format-ArchitectureString 'arm64' | Should-Be 'arm64'
        Format-ArchitectureString 'arm' | Should-Be 'arm64'
        Format-ArchitectureString 'aarch64' | Should-Be 'arm64'
        Format-ArchitectureString 'ARM64' | Should-Be 'arm64'
        Format-ArchitectureString 'ARM' | Should-Be 'arm64'
        Format-ArchitectureString 'AARCH64' | Should-Be 'arm64'
    }

    It 'should fallback to the default architecture on empty input' {
        Format-ArchitectureString '' | Should-Be $(Get-DefaultArchitecture)
        Format-ArchitectureString $null | Should-Be $(Get-DefaultArchitecture)
    }

    It 'should show an error with an invalid architecture' {
        { Format-ArchitectureString 'PPC' } | Should-Throw "*Invalid architecture: 'ppc'*"
    }
}

Describe 'substitute' -Tag 'Scoop' {
    It 'should properly handle keys that are substrings of other keys' {
        $params = @{}

        # Run repeatedly (10 times) to reduce the likelihood of accidental correct ordering.
        1 .. 10 | ForEach-Object {
            $params["`$name$($_)"] = "$($_).exe"
            $params["`$name$($_)NoExt"] = "$_"

            substitute ("`$name$($_)NoExt") $params $false | Should-Be "$_"
        }
    }
}
Describe 'Get-CommandLiteral' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        $pathDir = Join-Path $TestDrive 'literal-path'
        $lookalikeDir = Join-Path $TestDrive 'literal-lookalike'
        $decoyDir = Join-Path $TestDrive 'literal-decoy'
        $null = [IO.Directory]::CreateDirectory($pathDir)
        $null = [IO.Directory]::CreateDirectory($lookalikeDir)
        $null = [IO.Directory]::CreateDirectory($decoyDir)
        [IO.File]::WriteAllText("$pathDir\br[a]cket.exe", '')
        [IO.File]::WriteAllText("$lookalikeDir\bracket.exe", '')
        [IO.File]::WriteAllText("$decoyDir\clasper.exe", '')
    }

    It 'resolves a command name containing a wildcard character to the literal file on PATH' {
        $oldPath = $env:PATH
        $rest = (($oldPath -split ';') | Where-Object { $_ -and $_ -ne $pathDir -and $_ -ne $lookalikeDir -and $_ -ne $decoyDir }) -join ';'
        $env:PATH = "$pathDir;$lookalikeDir;$rest"
        try {
            (Get-CommandLiteral 'br[a]cket.exe').Path | Should-Be "$pathDir\br[a]cket.exe"
        } finally {
            $env:PATH = $oldPath
        }
    }

    It 'resolves a command name with a wildcard character and no extension' {
        $oldPath = $env:PATH
        $rest = (($oldPath -split ';') | Where-Object { $_ -and $_ -ne $pathDir -and $_ -ne $lookalikeDir -and $_ -ne $decoyDir }) -join ';'
        $env:PATH = "$pathDir;$lookalikeDir;$rest"
        try {
            (Get-CommandLiteral 'br[a]cket').Path | Should-Be "$pathDir\br[a]cket.exe"
        } finally {
            $env:PATH = $oldPath
        }
    }

    It 'returns nothing for a command that does not exist' {
        Get-CommandLiteral 'scoop-no-such-command' | Should-BeNull
    }

    It 'resolves a full path containing a wildcard character' {
        $full = "$pathDir\br[a]cket.exe"
        (Get-CommandLiteral $full).Path | Should-Be $full
    }

    It 'does not resolve a wildcard command name from a look-alike on PATH' {
        $oldPath = $env:PATH
        $rest = (($oldPath -split ';') | Where-Object { $_ -and $_ -ne $pathDir -and $_ -ne $lookalikeDir -and $_ -ne $decoyDir }) -join ';'
        $env:PATH = "$decoyDir;$rest"
        try {
            Get-CommandLiteral 'cl[a]sper.exe' | Should-BeNull
        } finally {
            $env:PATH = $oldPath
        }
    }
}

Describe 'Get-CommandPath' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        $pathDir = Join-Path $TestDrive 'literal-path'
        $lookalikeDir = Join-Path $TestDrive 'literal-lookalike'
        $null = [IO.Directory]::CreateDirectory($pathDir)
        $null = [IO.Directory]::CreateDirectory($lookalikeDir)
        [IO.File]::WriteAllText("$pathDir\br[a]cket.exe", '')
        [IO.File]::WriteAllText("$lookalikeDir\bracket.exe", '')
    }

    It 'resolves a command name containing a wildcard character to the literal file' {
        $pathDir = Join-Path $TestDrive 'literal-path'
        $lookalikeDir = Join-Path $TestDrive 'literal-lookalike'
        $oldPath = $env:PATH
        $rest = (($oldPath -split ';') | Where-Object { $_ -and $_ -ne $pathDir -and $_ -ne $lookalikeDir }) -join ';'
        $env:PATH = "$pathDir;$lookalikeDir;$rest"
        try {
            Get-CommandPath 'br[a]cket.exe' | Should-Be "$pathDir\br[a]cket.exe"
        } finally {
            $env:PATH = $oldPath
        }
    }
}

Describe 'Show-DeprecatedWarning' -Tag 'Scoop' {
    BeforeAll {
        . "$PSScriptRoot\..\lib\manifest.ps1" # 'arch_specific'
        $script = "rm_shim 'shim-test' '$TestDrive' 'app'`r`nrm_shim 'shim-test' '$TestDrive' 'app'`r`nshim 'target' `$false 'shim-test'`r`nshim 'target' `$false 'shim-test'"
        $manifest = [PSCustomObject]@{
            installer   = [PSCustomObject]@{ script = $script }
            uninstaller = [PSCustomObject]@{ script = $script }
        }
    }

    It 'warns once per deprecated function' {
        Mock warn { }
        Mock Remove-Shim { }
        Mock New-Shim { }

        Invoke-HookScript -HookType 'uninstaller' -Manifest $manifest -ProcessorArchitecture '64bit' 6>$null

        Should-Invoke warn -Times 1 -Exactly -ParameterFilter { $msg -like '"rm_shim"*' }
        Should-Invoke warn -Times 1 -Exactly -ParameterFilter { $msg -like '"shim"*' }
    }

    It 'warns again for the next manifest script' {
        Mock warn { }
        Mock Remove-Shim { }
        Mock New-Shim { }

        Invoke-HookScript -HookType 'installer' -Manifest $manifest -ProcessorArchitecture '64bit' 6>$null
        Invoke-HookScript -HookType 'uninstaller' -Manifest $manifest -ProcessorArchitecture '64bit' 6>$null

        Should-Invoke warn -Times 2 -Exactly -ParameterFilter { $msg -like '"rm_shim"*' }
        Should-Invoke warn -Times 2 -Exactly -ParameterFilter { $msg -like '"shim"*' }
    }
}

Describe 'Invoke-GitParallel' -Tag 'Scoop' {
    BeforeAll {
        $repoA = Join-Path $TestDrive 'repo a'
        $repoB = Join-Path $TestDrive 'repo-b'
        $notRepo = Join-Path $TestDrive 'not-a-repo'
        $repoA, $repoB, $notRepo | ForEach-Object { New-Item -ItemType Directory -Path $_ | Out-Null }
        $repoA, $repoB | ForEach-Object { git init -q $_ }
        # keep git from discovering an enclosing repository above $TestDrive
        $env:GIT_CEILING_DIRECTORIES = $TestDrive
    }
    AfterAll {
        Remove-Item Env:\GIT_CEILING_DIRECTORIES -ErrorAction Ignore
    }

    It 'returns one result per directory in input order, with exit codes' {
        $res = @(Invoke-GitParallel -Path $repoA, $notRepo, $repoB -ArgumentList @('rev-parse', '--is-inside-work-tree'))
        $res.Count | Should-Be 3
        $res.Path | Should-BeCollection @($repoA, $notRepo, $repoB)
        $res[0].ExitCode | Should-Be 0
        $res[0].Output | Should-Be 'true'
        $res[1].ExitCode | Should-NotBe 0
        ($res[1].ErrorOutput -join "`n") | Should-MatchString 'not a git repository'
        $res[2].ExitCode | Should-Be 0
    }

    It 'processes every directory when throttled to one' {
        $dirs = $repoA, $repoB, $repoA, $repoB
        $res = @(Invoke-GitParallel -Path $dirs -ArgumentList @('rev-parse', '--is-inside-work-tree') -ThrottleLimit 1)
        $res.Count | Should-Be 4
        $res.ExitCode | Should-BeCollection @(0, 0, 0, 0)
    }

    It 'passes arguments containing spaces, quotes and trailing backslashes intact' {
        $res = Invoke-GitParallel -Path $repoA -ArgumentList @('rev-parse', '--sq-quote', 'a b', 'c"d', 'e f\')
        $res.Output | Should-Be " 'a b' 'c`"d' 'e f\'"
    }
}

Describe 'Update-GitBranch' -Tag 'Scoop' {
    BeforeAll {
        # isolate from the user's git config (signing, pull.rebase, hooks, ...)
        $env:GIT_CEILING_DIRECTORIES = $TestDrive
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'gitconfig'
        Set-Content -Path $env:GIT_CONFIG_GLOBAL -Value "[user]`n`tname = test`n`temail = test@example.com"

        function Set-TestCommit($Repo, $File, $Content) {
            Set-Content -LiteralPath (Join-Path $Repo $File) -Value $Content
            git -C $Repo add -A
            git -C $Repo commit -q -m "edit $File"
        }
        # origin with app.json + other.json, and a clone tracking it
        function New-TestClone($Name) {
            $origin = Join-Path $TestDrive "$Name-origin"
            $clone = Join-Path $TestDrive $Name
            git init -q -b master $origin
            Set-TestCommit $origin 'app.json' 'v1'
            Set-TestCommit $origin 'other.json' 'x'
            git clone -q $origin $clone
            return $origin, $clone
        }
        function Get-Head($Repo, $Rev = 'HEAD') { git -C $Repo rev-parse $Rev }
    }
    AfterAll {
        'GIT_CEILING_DIRECTORIES', 'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_GLOBAL' | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction Ignore }
    }

    It 'fast-forwards when there are no local commits' {
        $origin, $clone = New-TestClone 'ff'
        Set-TestCommit $origin 'app.json' 'v2'
        git -C $clone fetch -q

        $res = Update-GitBranch -Path $clone
        $res.Status | Should-Be 'FastForward'
        $res.NewHead | Should-Be (Get-Head $origin)
        $res.Base | Should-Be $res.OldHead
        Get-Content (Join-Path $clone 'app.json') | Should-Be 'v2'
    }

    It 'rebases a local tweak commit onto upstream' {
        $origin, $clone = New-TestClone 'rebase'
        Set-TestCommit $clone 'other.json' 'my tweak'
        $tweakBase = Get-Head $clone 'HEAD~1'
        Set-TestCommit $origin 'app.json' 'v2'
        git -C $clone fetch -q

        $res = Update-GitBranch -Path $clone
        $res.Status | Should-Be 'Rebased'
        $res.Base | Should-Be $tweakBase
        $res.Upstream | Should-Be (Get-Head $origin)
        Get-Head $clone 'HEAD~1' | Should-Be (Get-Head $origin)
        Get-Content (Join-Path $clone 'app.json') | Should-Be 'v2'
        Get-Content (Join-Path $clone 'other.json') | Should-Be 'my tweak'
    }

    It 'aborts on conflict and leaves the branch untouched' {
        $origin, $clone = New-TestClone 'conflict'
        Set-TestCommit $clone 'app.json' 'my tweak'
        $before = Get-Head $clone
        Set-TestCommit $origin 'app.json' 'v2'
        git -C $clone fetch -q

        $res = Update-GitBranch -Path $clone
        $res.Status | Should-Be 'Conflict'
        $res.Conflicts | Should-Be 'app.json'
        $res.NewHead | Should-Be $before
        Get-Head $clone | Should-Be $before
        Test-Path (Join-Path $clone '.git\rebase-merge') | Should-BeFalse
        git -C $clone status --porcelain | Should-BeNull
    }

    It 'keeps uncommitted changes across a rebase' {
        $origin, $clone = New-TestClone 'dirty'
        Set-TestCommit $clone 'other.json' 'my tweak'
        Add-Content -LiteralPath (Join-Path $clone 'other.json') -Value 'wip'
        Set-TestCommit $origin 'app.json' 'v2'
        git -C $clone fetch -q

        (Update-GitBranch -Path $clone).Status | Should-Be 'Rebased'
        Get-Content (Join-Path $clone 'other.json') | Should-BeCollection @('my tweak', 'wip')
    }

    It 'reports up to date when only local commits are ahead' {
        $null, $clone = New-TestClone 'ahead'
        Set-TestCommit $clone 'other.json' 'my tweak'
        $before = Get-Head $clone

        $res = Update-GitBranch -Path $clone
        $res.Status | Should-Be 'UpToDate'
        $res.NewHead | Should-Be $before
    }

    It 'does not touch a rebase the user left in progress' {
        $origin, $clone = New-TestClone 'busy'
        Set-TestCommit $clone 'app.json' 'my tweak'
        Set-TestCommit $origin 'app.json' 'v2'
        git -C $clone fetch -q
        git -C $clone rebase -q '@{upstream}' *> $null

        (Update-GitBranch -Path $clone).Status | Should-Be 'Busy'
        Test-Path (Join-Path $clone '.git\rebase-merge') | Should-BeTrue
    }

    It 'reports a branch without upstream' {
        $null, $clone = New-TestClone 'noupstream'
        git -C $clone checkout -q -b local-only

        (Update-GitBranch -Path $clone).Status | Should-Be 'NoUpstream'
    }
}

Describe 'app_status' -Tag 'Scoop' {
    BeforeAll {
        . "$PSScriptRoot\..\lib\manifest.ps1" # 'install_info' 'Find-AppBucket'
        . "$PSScriptRoot\..\lib\buckets.ps1" # 'Find-BucketDirectory'
        . "$PSScriptRoot\..\lib\versions.ps1" # 'Select-CurrentVersion'
    }
    BeforeEach {
        Mock Test-Path { $false }
        Mock get_config { $false }
    }

    It 'reports the bucket version of an app installed from an auto-generated manifest' {
        Mock Select-CurrentVersion { '3.24.0' }
        Mock install_info { [PSCustomObject]@{ url = (usermanifest 'foo') } }
        Mock manifest { [PSCustomObject]@{ version = '3.24.0'; depends = @('dep') } }
        Mock Find-AppBucket { [PSCustomObject]@{ version = '3.24.1'; depends = @('newdep') }, 'extras' }
        Mock installed { $app -ne 'dep' }

        $status = app_status 'foo' $false

        $status.latest_version | Should-Be '3.24.1'
        $status.outdated | Should-BeTrue
        $status.pinned | Should-BeTrue
        # the dependencies of the installed version, not of the newer one
        $status.missing_deps | Should-BeCollection -Count 1
        $status.missing_deps[0] | Should-Be 'dep'
    }

    It 'keeps the manifest of an app installed from a bucket' {
        Mock Select-CurrentVersion { '3.24.1' }
        Mock install_info { [PSCustomObject]@{ bucket = 'extras' } }
        Mock manifest { [PSCustomObject]@{ version = '3.24.1' } }
        Mock Find-AppBucket { [PSCustomObject]@{ version = '3.24.1' }, 'extras' }

        $status = app_status 'foo' $false

        $status.latest_version | Should-Be '3.24.1'
        $status.outdated | Should-BeFalse
        $status.pinned | Should-BeFalse
        Should-Invoke -CommandName Find-AppBucket -Times 0
    }
}
