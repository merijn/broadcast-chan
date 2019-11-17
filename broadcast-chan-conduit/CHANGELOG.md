0.2.1 [2019.11.17]
------------------
* Fix resource management bug resulting from using `MonadUnliftIO` to run
  `MonadResource` code in multiple threads. This version properly increments
  resource count for every thread.

0.2.0.2 [2019.03.30]
--------------------
* Update bounds for GHC 8.6

0.2.0.1 [2018.09.24]
--------------------
* Ditch GHC 7.6.3 support.

0.2.0 [2018.09.20]
------------------
* Initial release.
