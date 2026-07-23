BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Resolve-SbxRuntime' {
    It 'returns wslc on Windows' { Resolve-SbxRuntime -IsMac:$false -Override $null | Should -Be 'wslc' }
    It 'returns docker on macOS' { Resolve-SbxRuntime -IsMac:$true  -Override $null | Should -Be 'docker' }
    It 'honors an explicit override' { Resolve-SbxRuntime -IsMac:$true -Override 'podman' | Should -Be 'podman' }
}

Describe 'Test-SbxBenignRuntimeError' {
    It 'recognizes "no such container" as benign' {
        Test-SbxBenignRuntimeError 'Error: No such container: sbx-foo-abc' | Should -BeTrue
    }
    It 'recognizes "no such object" as benign' {
        Test-SbxBenignRuntimeError 'Error response from daemon: no such object: sbx-foo' | Should -BeTrue
    }
    It 'recognizes "not found" as benign' {
        Test-SbxBenignRuntimeError 'sbx-foo-abc: not found' | Should -BeTrue
    }
    It 'recognizes "is not running" as benign' {
        Test-SbxBenignRuntimeError 'Error: Container sbx-foo-abc is not running' | Should -BeTrue
    }
    It 'is case-insensitive' {
        Test-SbxBenignRuntimeError 'NO SUCH CONTAINER: sbx-foo' | Should -BeTrue
    }
    It 'returns false for null or empty input' {
        Test-SbxBenignRuntimeError $null | Should -BeFalse
        Test-SbxBenignRuntimeError ''    | Should -BeFalse
    }
    It 'returns false for an unrelated/real failure' {
        Test-SbxBenignRuntimeError 'Cannot connect to the Docker daemon' | Should -BeFalse
    }
}
