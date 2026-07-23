BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Build-SbxWtBody' {
    It 'invokes the given runtime, not a hardcoded wslc' {
        $body = Build-SbxWtBody -RunArgs @('run','-it','img') -Runtime 'podman'
        $body | Should -Match "& 'podman' @a"
        $body | Should -Not -Match 'wslc'
    }

    It 'uses wslc cleanup verbs (remove / volume remove) for wslc' {
        $body = Build-SbxWtBody -RunArgs @('run') -Name 'sbx-foo-abc' -Runtime 'wslc'
        $body | Should -Match "& 'wslc' stop 'sbx-foo-abc'"
        $body | Should -Match "& 'wslc' remove 'sbx-foo-abc'"
        $body | Should -Match "& 'wslc' volume remove 'sbx-foo-abc-proj'"
    }

    It 'uses docker-style cleanup verbs (rm / volume rm) for other runtimes' {
        $body = Build-SbxWtBody -RunArgs @('run') -Name 'sbx-foo-abc' -Runtime 'podman'
        $body | Should -Match "& 'podman' stop 'sbx-foo-abc'"
        $body | Should -Match "& 'podman' rm 'sbx-foo-abc'"
        $body | Should -Match "& 'podman' volume rm 'sbx-foo-abc-proj'"
    }

    It 'omits cleanup when no name is given' {
        $body = Build-SbxWtBody -RunArgs @('run') -Runtime 'wslc'
        $body | Should -Not -Match 'finally'
        $body | Should -Not -Match 'stop'
    }

    It 'emits run args as single-quoted literals so $, space, and quote survive' {
        $body = Build-SbxWtBody -RunArgs @('run', 'C:\di r\$proj', "it's") -Runtime 'wslc'
        $body | Should -Match ([regex]::Escape("'C:\di r\`$proj'".Replace('`','')))
        $body | Should -Match ([regex]::Escape("'it''s'"))
    }

    It 'defaults the runtime to Resolve-SbxRuntime' {
        $expected = Resolve-SbxRuntime
        $body = Build-SbxWtBody -RunArgs @('run')
        $body | Should -Match "& '$expected' @a"
    }
}
