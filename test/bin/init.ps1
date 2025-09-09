#Requires -Version 5.1
Write-Output "PowerShell: $($PSVersionTable.PSVersion)"
Write-Output 'Check and install testsuite dependencies ...'

# 1. Define the path to a 'modules' directory relative to the script.
$ModulesPath = Join-Path -Path $PSScriptRoot -ChildPath '../modules'

# 2. List the modules required for this script.
$RequiredModules = @{
    Pester = '5.7.1'
    PSReadline = '2.3.4'
    BuildHelpers = '2.0.16'
    PSScriptAnalyzer = '1.24.0'
}

# 3. Create the 'modules' directory if it does not exist.
if (-not (Test-Path -Path $ModulesPath)) {
    New-Item -Path $ModulesPath -ItemType Directory | Out-Null
}

# 4. Check for and save each required module if it's missing.
$RequiredModules.GetEnumerator() | ForEach-Object {
    $ModuleName = $_.Key
    $RequiredVersion = $_.Value

    # Look in the sandbox itself. Get-Module -ListAvailable would miss it (PSModulePath is
    # only extended in step 5, below) and would also accept a globally installed copy,
    # which defeats the point of vendoring these.
    $SandboxedModule = Join-Path -Path $ModulesPath -ChildPath "$ModuleName\$RequiredVersion"

    if (-not (Test-Path -Path $SandboxedModule)) {
        Write-Warning "Module '$ModuleName' version '$RequiredVersion' not found. Downloading..."
        # Save the module to our local './modules' folder without installing it globally.
        Save-Module -Name $ModuleName -RequiredVersion $RequiredVersion -Path $ModulesPath -Repository PSGallery
    }
}

# 5. Add the local modules path to the current session's PSModulePath.
#    This ensures Import-Module finds our local modules first.
$mach_ = [System.Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
$user_ = [System.Environment]::GetEnvironmentVariable('PSModulePath', 'User')
$PrestinePSModulePath = "$mach_;$user_"

$env:PSModulePath = "$ModulesPath;$PrestinePSModulePath"
