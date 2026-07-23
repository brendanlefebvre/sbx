BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'ConvertFrom-SbxArgs (v2)' {
    It 'no args = attach to the hub' {
        $o = ConvertFrom-SbxArgs @()
        $o.Command | Should -Be 'attach'
        $o.Target  | Should -BeNullOrEmpty
        $o.Window  | Should -Be 'here'
    }
    It 'bare name = attach to that project session' {
        $o = ConvertFrom-SbxArgs @('foo')
        $o.Command | Should -Be 'attach'
        $o.Target  | Should -Be 'foo'
    }
    It 'a path-looking arg errors with a pointer to add' {
        { ConvertFrom-SbxArgs @('C:\src\foo') } | Should -Throw '*sbx add*'
        { ConvertFrom-SbxArgs @('src/foo') }    | Should -Throw '*sbx add*'
    }
    It 'parses add <path>' {
        $o = ConvertFrom-SbxArgs @('add', 'C:\src\foo')
        $o.Command | Should -Be 'add'
        $o.Target  | Should -Be 'C:\src\foo'
    }
    It 'parses rm <name>' {
        $o = ConvertFrom-SbxArgs @('rm', 'foo')
        $o.Command | Should -Be 'rm'
        $o.Target  | Should -Be 'foo'
    }
    It 'parses sync <name> <op>' {
        $o = ConvertFrom-SbxArgs @('sync', 'foo', 'push')
        $o.Command   | Should -Be 'sync'
        $o.Target    | Should -Be 'foo'
        $o.Operation | Should -Be 'push'
    }
    It 'parses ls / rebuild / stop / scratch / status' {
        (ConvertFrom-SbxArgs @('ls')).Command      | Should -Be 'ls'
        (ConvertFrom-SbxArgs @('rebuild')).Command | Should -Be 'rebuild'
        (ConvertFrom-SbxArgs @('stop')).Command    | Should -Be 'stop'
        (ConvertFrom-SbxArgs @('scratch')).Command | Should -Be 'scratch'
        (ConvertFrom-SbxArgs @('status')).Command  | Should -Be 'status'
    }
    It 'parses --new-window / --window / --win and --tab wherever they appear' {
        (ConvertFrom-SbxArgs @('--new-window')).Window          | Should -Be 'window'
        (ConvertFrom-SbxArgs @('foo', '--window')).Window       | Should -Be 'window'
        (ConvertFrom-SbxArgs @('--win', 'scratch')).Window      | Should -Be 'window'
        (ConvertFrom-SbxArgs @('foo', '--tab')).Window          | Should -Be 'tab'
    }
    It 'the retired --here flag is now an unknown option' {
        { ConvertFrom-SbxArgs @('--here') } | Should -Throw '*Unknown option*'
    }
    It 'errors on missing subcommand arguments' {
        { ConvertFrom-SbxArgs @('add') }          | Should -Throw '*add*'
        { ConvertFrom-SbxArgs @('rm') }           | Should -Throw '*rm*'
        { ConvertFrom-SbxArgs @('sync', 'foo') }  | Should -Throw '*sync*'
    }
    It 'retired v1 flags are unknown options' {
        { ConvertFrom-SbxArgs @('--ssh', 'foo') }        | Should -Throw '*Unknown option*'
        { ConvertFrom-SbxArgs @('--name', 'x', 'foo') }  | Should -Throw '*Unknown option*'
    }
    It 'rejects . and .. as a project name (traversal guard)' {
        { ConvertFrom-SbxArgs @('..') }             | Should -Throw '*invalid project name*'
        { ConvertFrom-SbxArgs @('.') }              | Should -Throw '*invalid project name*'
        { ConvertFrom-SbxArgs @('rm', '..') }       | Should -Throw '*invalid project name*'
        { ConvertFrom-SbxArgs @('rm', '.') }        | Should -Throw '*invalid project name*'
        { ConvertFrom-SbxArgs @('sync', '..', 'push') } | Should -Throw '*invalid project name*'
        { ConvertFrom-SbxArgs @('sync', '.', 'push') }  | Should -Throw '*invalid project name*'
    }
}
