0.3.0 [????.??.??]
------------------
* Fixed Haddock links.
* Generalised `readBChan`/`writeBChan` in `BroadcastChan.Throw` to use
  `MonadIO`.

0.2.1.2 [2021.12.01]
--------------------
* Update bounds for GHC 9.0 and 9.2.
* Hacky fix of a tricky race condition
  [#3](https://github.com/merijn/broadcast-chan/issues/3).

0.2.1.1 [2020.03.05]
--------------------
* Updated imports to support `unliftio-core` 0.2.x.

0.2.1 [2019.11.17]
------------------
* Adds `ThreadBracket`, `runParallelWith`, and `runParallelWith_` to
  `BroadcastChan.Extra` to support thread related resource management. This is
  required to fix `broadcast-chan-conduit`'s use of `MonadResource`.

0.2.0.2 [2019.03.30]
--------------------
* GHC 8.6/MonadFail compatibility fix

0.2.0.1 [2018.09.24]
--------------------
* Loosen STM bounds for new stackage release.
* Ditch GHC 7.6.3 support.

0.2.0 [2018.09.20]
------------------
* Complete rework to be actually practical.
* Switched to standalone module hierarchy.
* Added functionality for parallel tasks.
* Add module which uses exceptions, instead of results to signal failure.
