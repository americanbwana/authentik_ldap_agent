Describe 'Repository credential safety' {
    It 'does not contain a plaintext environment password' {
        $files = Get-ChildItem -Path (Join-Path $PSScriptRoot '..') -Recurse -File |
            Where-Object FullName -NotMatch '[\\/]\.git[\\/]'
        $matches = $files | Select-String -SimpleMatch 'VMware123!VMware123!' -ErrorAction SilentlyContinue
        $matches | Should -BeNullOrEmpty
    }
}
