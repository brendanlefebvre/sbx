BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'ConvertTo-SbxMountPath' {
    It 'translates a Windows path to the forward-slash Windows form (per docs/FINDINGS.md)' {
        ConvertTo-SbxMountPath 'C:\Users\user\src\foo' | Should -Be 'C:/Users/user/src/foo'
    }
    It 'normalizes an already-forward-slash path and strips a trailing slash' {
        ConvertTo-SbxMountPath 'C:/Users/user/src/foo/' | Should -Be 'C:/Users/user/src/foo'
    }
    It 'throws on a non-drive (UNC) path' {
        { ConvertTo-SbxMountPath '\\server\share\x' } | Should -Throw
    }
}

Describe 'ConvertTo-SbxMountPath -Posix (macOS)' {
    It 'passes an absolute POSIX path through, trimming a trailing slash' {
        ConvertTo-SbxMountPath '/Users/user/src/foo/' -Posix | Should -Be '/Users/user/src/foo'
    }
    It 'returns an already-clean absolute path unchanged' {
        ConvertTo-SbxMountPath '/Users/user/src/foo' -Posix | Should -Be '/Users/user/src/foo'
    }
    It 'throws on a relative path under -Posix' {
        { ConvertTo-SbxMountPath 'src/foo' -Posix } | Should -Throw
    }
    It 'never collapses root to empty' {
        ConvertTo-SbxMountPath '/' -Posix | Should -Be '/'
    }
}
