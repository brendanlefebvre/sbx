# One-time Claude login for sbx

## Windows (wslc)

Run once per machine (or after `wslc volume remove sbx-claude-auth`):

    wslc volume create sbx-claude-auth
    wslc run --rm -it -v "sbx-claude-auth:/home/agent/.claude" sbx:latest claude
    # complete the login in the container, then exit

Every `sbx` run mounts this volume at `/home/agent/.claude`, so containers are
already authenticated. To re-authenticate, remove the volume and repeat.

## macOS (Docker)

Run once per machine (or after `docker volume rm sbx-claude-auth`):

    docker volume create sbx-claude-auth
    docker run --rm -it -v "sbx-claude-auth:/home/agent/.claude" sbx:latest claude
    # complete the login in the container, then exit

Every `sbx` run mounts this volume at `/home/agent/.claude`, so containers are
already authenticated. To re-authenticate, remove the volume and repeat.
