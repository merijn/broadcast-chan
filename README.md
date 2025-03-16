BroadcastChan: Closable, fair, single-wakeup, broadcast channels
================================================================
[![BSD3](https://img.shields.io/badge/License-BSD-blue.svg)](https://en.wikipedia.org/wiki/BSD_License)
[![Hackage](https://img.shields.io/hackage/v/broadcast-chan.svg)](https://hackage.haskell.org/package/broadcast-chan)
[![Build Status](https://github.com/merijn/broadcast-chan/actions/workflows/haskell-ci.yml/badge.svg)](https://github.com/merijn/broadcast-chan/actions/workflows/haskell-ci.yml/)

A closable, fair, single-wakeup channel that avoids the 0 reader space leak
that `Control.Concurrent.Chan` from base suffers from.

The `Chan` type from `Control.Concurrent.Chan` consists of both a read and
write end combined into a single value. This means there is always at least 1
read end for a `Chan`, which keeps any values written to it alive. This is a
problem for applications/libraries that want to have a channel that can have
zero listeners.

Suppose we have an library that produces events and we want to let users
register to receive events. If we use a channel and write all events to it, we
would like to drop and garbage collect any events that take place when there
are 0 listeners. The always present read end of `Chan` from base makes this
impossible. We end up with a `Chan` that forever accumulates more and more
events that will never get removed, resulting in a memory leak.

`BroadcastChan` splits channels into separate read and write ends. Any message
written to a a channel with no existing read end is immediately dropped so it
can be garbage collected. Once a read end is created, all messages written to
the channel will be accessible to that read end.

Once all read ends for a channel have disappeared and been garbage collected,
the channel will return to dropping messages as soon as they are written.

Why should I use `BroadcastChan` over `Control.Concurrent.Chan`?
---
* `BroadcastChan` is closable,
* `BroadcastChan` has no 0 reader space leak,
* `BroadcastChan` has comparable or better performance.

Why should I use `BroadcastChan` over various (closable) STM channels?
---
* `BroadcastChan` is single-wakeup,
* `BroadcastChan` is fair,
* `BroadcastChan` performs better under contention.
