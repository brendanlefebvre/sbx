BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Invoke-SbxSync' {
    BeforeEach {
        $script:ws = Join-Path $TestDrive 'ws'
        New-Item -ItemType Directory -Force (Join-Path $script:ws 'foo') | Out-Null
    }
    It 'runs the allowlisted git op in the project workspace dir' {
        Mock -CommandName git -MockWith { $script:seen = $args }
        Invoke-SbxSync -Name 'foo' -Operation 'push' -WorkspaceDir $script:ws
        ($script:seen -join ' ') | Should -Be "-C $(Join-Path $script:ws 'foo') push"
    }
    It 'rejects a non-allowlisted operation' {
        Mock -CommandName git -MockWith { throw 'must not run' }
        { Invoke-SbxSync -Name 'foo' -Operation 'push --force' -WorkspaceDir $script:ws } | Should -Throw '*one of*'
        { Invoke-SbxSync -Name 'foo' -Operation 'status'       -WorkspaceDir $script:ws } | Should -Throw '*one of*'
    }
    It 'throws for a project not in the workspace' {
        { Invoke-SbxSync -Name 'ghost' -Operation 'push' -WorkspaceDir $script:ws } | Should -Throw '*no project*'
    }
    It 'throws for a traversal name even though the resolved parent dir exists' {
        # Join-Path $ws '..' resolves to $ws's OWN parent, which genuinely exists —
        # the naive Test-Path guard alone would let this through. The direct-child
        # containment check must catch it.
        Mock -CommandName git -MockWith { throw 'must not run' }
        { Invoke-SbxSync -Name '..' -Operation 'push' -WorkspaceDir $script:ws } | Should -Throw '*no project*'
    }
}
