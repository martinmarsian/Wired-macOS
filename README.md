# WiredSwift Client

WiredSwift Client is an implementation of the Wired 2.0 protocol written in Swift. 

## Requirements

* macOS 10.14

## wiredsyncd

`wiredsyncd` is the background synchronization daemon used by Wired Client for folder sync. It is intentionally separate from the GUI so sync pairs can keep running, be restarted cleanly, and be inspected independently when something goes wrong.

This section focuses on practical operation rather than implementation details. If you only need to use sync from the app, Wired Client will normally install and manage the daemon for you. The standalone commands below are mainly useful for development, support, and troubleshooting.

### What the daemon does

At a high level, `wiredsyncd`:

* stores sync pair configuration in `~/Library/Application Support/WiredSync/config.json`
* stores runtime state and sync metadata in `~/Library/Application Support/WiredSync/state.sqlite`
* stores sync passwords in the macOS Keychain rather than in plaintext project files
* exposes a local JSON-RPC control socket at `~/Library/Application Support/WiredSync/run/wiredsyncd.sock`
* runs periodic sync passes in the background
* connects to a Wired server using the same protocol definition (`wired.xml`) as the main app

Each sync pair binds:

* one remote folder on a Wired server
* one local folder on the Mac
* one sync mode: `server_to_client`, `client_to_server`, or `bidirectional`

The daemon also keeps a lightweight uploaded-file snapshot cache in SQLite. That cache is used to distinguish true changes from changes caused by the daemon's own previous uploads, which is especially important for bidirectional sync.

Passwords are not persisted in `config.json` or `state.sqlite`. They are stored in the current user's macOS Keychain and looked up by the daemon when it opens a server connection.

### How it integrates with Wired Client and Wired Server

Wired Client is responsible for installing, updating, and talking to `wiredsyncd`.

On macOS, the app installs the daemon under:

```text
~/Library/Application Support/WiredSync/daemon/wiredsyncd
```

and loads it with a per-user LaunchAgent:

```text
~/Library/LaunchAgents/fr.read-write.wiredsyncd.plist
```

The app then communicates with the daemon over the local Unix socket using JSON-RPC. Typical GUI actions such as enabling sync, pausing a pair, forcing a sync, or changing the sync policy are translated into RPC requests.

The daemon itself talks directly to the Wired server. It does not need the GUI once a pair has been registered. In other words:

* Wired Client manages configuration and lifecycle
* `wiredsyncd` performs sync work in the background
* Wired Server remains the remote source and destination for file operations

### Running wiredsyncd standalone

`wiredsyncd` was designed so it can also be launched outside the app.

Build it from the repository root:

```bash
cd wiredsyncd
swift build
```

Run it in the foreground:

```bash
WIRED_SYNCD_RESOURCE_ROOT="$(pwd)/../WiredSwift/Sources/WiredSwift/Resources" \
./.build/debug/wiredsyncd
```

If you built a release binary, replace `debug` with `release`.

The `WIRED_SYNCD_RESOURCE_ROOT` environment variable should point to a directory containing `wired.xml`. When the app manages the daemon for you, it sets this automatically. In standalone mode it is best to set it explicitly.

When started successfully, the daemon creates:

```text
~/Library/Application Support/WiredSync/run/wiredsyncd.sock
```

You can verify that it is reachable with a simple JSON-RPC `status` request:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":"status-1","method":"status"}' | nc -U "$HOME/Library/Application Support/WiredSync/run/wiredsyncd.sock"
```

Expected response shape:

```json
{"jsonrpc":"2.0","id":"status-1","result":{"version":"14","pairs_count":0,"active_pairs":0,"queue_depth":0,"socket_path":"...","config_path":"...","state_path":"...","running":true}}
```

### Standalone JSON-RPC examples

The daemon uses one-line JSON-RPC messages over the Unix socket. The examples below use `nc -U`, which is available on macOS.

List configured sync pairs:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":"list-1","method":"list_pairs"}' | nc -U "$HOME/Library/Application Support/WiredSync/run/wiredsyncd.sock"
```

Add a sync pair:

```bash
printf '%s\n' '{
  "jsonrpc":"2.0",
  "id":"add-1",
  "method":"add_pair",
  "params":{
    "remote_path":"/Shared/Documents",
    "local_path":"/Users/me/Documents/WiredSync/Documents",
    "mode":"bidirectional",
    "delete_remote_enabled":"false",
    "exclude_patterns":"*.tmp\n.DS_Store",
    "server_url":"wired.example.org",
    "login":"alice",
    "password":"secret"
  }
}' | tr -d '\n' | nc -U "$HOME/Library/Application Support/WiredSync/run/wiredsyncd.sock"
echo
```

Force an immediate sync pass for a specific remote path:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":"sync-1","method":"sync_now","params":{"remote_path":"/Shared/Documents","server_url":"wired.example.org","login":"alice"}}' | nc -U "$HOME/Library/Application Support/WiredSync/run/wiredsyncd.sock"
```

Pause or resume a pair once you know its `pair_id` from `list_pairs`:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":"pause-1","method":"pause_pair","params":{"pair_id":"PUT-PAIR-ID-HERE"}}' | nc -U "$HOME/Library/Application Support/WiredSync/run/wiredsyncd.sock"
```

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":"resume-1","method":"resume_pair","params":{"pair_id":"PUT-PAIR-ID-HERE"}}' | nc -U "$HOME/Library/Application Support/WiredSync/run/wiredsyncd.sock"
```

Fetch in-memory daemon logs:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":"logs-1","method":"logs_tail","params":{"count":"100"}}' | nc -U "$HOME/Library/Application Support/WiredSync/run/wiredsyncd.sock"
```

Ask the daemon to shut down cleanly:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":"shutdown-1","method":"shutdown"}' | nc -U "$HOME/Library/Application Support/WiredSync/run/wiredsyncd.sock"
```

### Troubleshooting and recovery

If sync stops working, the most useful first checks are:

```bash
ls -l "$HOME/Library/Application Support/WiredSync/run"
```

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":"status-2","method":"status"}' | nc -U "$HOME/Library/Application Support/WiredSync/run/wiredsyncd.sock"
```

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":"logs-2","method":"logs_tail","params":{"count":"200"}}' | nc -U "$HOME/Library/Application Support/WiredSync/run/wiredsyncd.sock"
```

If the daemon is app-managed, also inspect the LaunchAgent logs:

```bash
tail -n 200 "$HOME/Library/Logs/WiredSync/wiredsyncd.out.log"
```

```bash
tail -n 200 "$HOME/Library/Logs/WiredSync/wiredsyncd.err.log"
```

To stop the app-managed daemon:

```bash
launchctl bootout "gui/$(id -u)/fr.read-write.wiredsyncd"
```

To start it again:

```bash
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/fr.read-write.wiredsyncd.plist"
```

To see whether launchd knows about it:

```bash
launchctl print "gui/$(id -u)/fr.read-write.wiredsyncd"
```

To verify that the socket is actually owned by your user and being listened to:

```bash
lsof -U | grep wiredsyncd
```

If you want the most direct debugging setup, stop the LaunchAgent first and then run the daemon manually in the foreground. That makes stdout, stderr, and crashes much easier to inspect.

### Common things to check

When debugging a sync issue, these are the most common causes:

* the LaunchAgent is still running an old daemon build after you changed the code
* `wired.xml` cannot be found by the standalone daemon because `WIRED_SYNCD_RESOURCE_ROOT` was not set
* the Unix socket exists but the daemon behind it is gone
* the configured local path no longer exists
* the server URL or login is correct, but the Keychain entry used by the pair is missing or outdated
* the remote folder permissions allow partial operations but not full listing or deletion
* exclude patterns are missing for files generated by another tool in the synced folder

The daemon is conservative by design. If it cannot safely determine the remote state, it will often skip part of a sync cycle instead of guessing and amplifying a conflict.

### Notes for advanced users

Some implementation details are useful to know when reading logs:

* the daemon scans and reconciles pairs periodically rather than relying only on file system event streams
* the control socket is restricted to the current macOS user
* the daemon version is checked by Wired Client, and a mismatch causes the app to reinstall/restart the daemon
* sync metadata is persisted in `state.sqlite`, so deleting that file resets the daemon's local sync memory

Deleting `config.json` or `state.sqlite` is a heavy-handed recovery step and should only be done if you intentionally want to reset sync configuration or cache state.

## Contribute

You are welcome to contribute using issues and pull-requests if you want to.

Focus is on:

* socket IO stability: the quality of in/out data interpretation and management through the Wired socket
* mutli-threading stability: the ability to interact smoothly between connections and UIs
* low-level unit tests: provides a strong implementation to enforce the integrity of the specification
* specification compliance: any not yet implemented features that require kilometers of code…
* limit regression from the original implementation

Check the GitHub « Projects » page to get a sneap peek on the project insights and progress:  https://github.com/nark/WiredSwift/projects

## License

This code is distributed under BSD license, and it is free for personal or commercial use.
        
- Copyright (c) 2003-2009 Axel Andersson, All rights reserved.
- Copyright (c) 2011-2020 Rafaël Warnault, All rights reserved.
        
Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
        
Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
        
THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
