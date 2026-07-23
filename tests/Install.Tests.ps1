BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Install-SbxShim' {
    It 'writes an executable sbx shim that execs pwsh against sbx-cli.ps1' {
        $tmp  = Join-Path ([IO.Path]::GetTempPath()) ("sbxbin-" + [guid]::NewGuid())
        $shim = Install-SbxShim -RepoDir '/repo/sbx' -BinDir $tmp
        try {
            Test-Path $shim | Should -BeTrue
            (Split-Path -Leaf $shim) | Should -Be 'sbx'
            (Get-Content $shim -Raw) | Should -BeLike '*exec pwsh -NoProfile -File "/repo/sbx/sbx-cli.ps1"*'
            (Get-Content $shim)[0] | Should -Be '#!/bin/sh'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}
