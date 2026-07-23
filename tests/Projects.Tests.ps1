BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Get-SbxLiveSessions' {
    It 'returns empty when sbx-main is not running' {
        Mock -CommandName Get-SbxMainState -MockWith { 'absent' }
        @(Get-SbxLiveSessions -Runtime 'wslc').Count | Should -Be 0
    }
}

Describe 'Get-SbxProjects' {
    BeforeEach {
        $script:ws  = Join-Path $TestDrive 'ws'
        $script:man = Join-Path $TestDrive 'origins.json'
        New-Item -ItemType Directory -Force (Join-Path $script:ws 'foo') | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $script:ws 'bar.baz') | Out-Null
        Save-SbxOrigins -Origins @{ 'foo' = 'C:\src\foo'; 'bar.baz' = 'C:\src\bar.baz' } -ManifestPath $script:man
    }
    It 'lists workspace dirs with origin and live-session flag' {
        Mock -CommandName Get-SbxLiveSessions -MockWith { @('foo', 'hub') }
        $r = Get-SbxProjects -WorkspaceDir $script:ws -ManifestPath $script:man -Runtime 'wslc'
        @($r).Count | Should -Be 2
        ($r | Where-Object Name -eq 'foo').Origin  | Should -Be 'C:\src\foo'
        ($r | Where-Object Name -eq 'foo').Session | Should -BeTrue
        ($r | Where-Object Name -eq 'bar.baz').Session | Should -BeFalse   # sanitized name not live
    }
    It 'ignores dot-directories (infrastructure, e.g. .sbx)' {
        New-Item -ItemType Directory -Force (Join-Path $script:ws '.sbx') | Out-Null
        Mock -CommandName Get-SbxLiveSessions -MockWith { @() }
        $r = Get-SbxProjects -WorkspaceDir $script:ws -ManifestPath $script:man -Runtime 'wslc'
        @($r).Count | Should -Be 2
        @($r).Name  | Should -Not -Contain '.sbx'
    }
    It 'returns nothing for a missing workspace dir' {
        Get-SbxProjects -WorkspaceDir (Join-Path $TestDrive 'nope') -ManifestPath $script:man -Runtime 'wslc' |
            Should -BeNullOrEmpty
    }
}
