{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE Safe #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan
-- Copyright   :  (C) 2014-2018 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- A closable, fair, single-wakeup channel that avoids the 0 reader space leak
-- that @"Control.Concurrent.Chan"@ from base suffers from.
--
-- The @Chan@ type from @"Control.Concurrent.Chan"@ consists of both a read
-- and write end combined into a single value. This means there is always at
-- least 1 read end for a @Chan@, which keeps any values written to it alive.
-- This is a problem for applications/libraries that want to have a channel
-- that can have zero listeners.
--
-- Suppose we have an library that produces events and we want to let users
-- register to receive events. If we use a channel and write all events to it,
-- we would like to drop and garbage collect any events that take place when
-- there are 0 listeners. The always present read end of @Chan@ from base
-- makes this impossible. We end up with a @Chan@ that forever accumulates
-- more and more events that will never get removed, resulting in a memory
-- leak.
--
-- @"BroadcastChan"@ splits channels into separate read and write ends. Any
-- message written to a a channel with no existing read end is immediately
-- dropped so it can be garbage collected. Once a read end is created, all
-- messages written to the channel will be accessible to that read end.
--
-- Once all read ends for a channel have disappeared and been garbage
-- collected, the channel will return to dropping messages as soon as they are
-- written.
--
-- __Why should I use "BroadcastChan" over "Control.Concurrent.Chan"?__
--
-- * @"BroadcastChan"@ is closable,
--
-- * @"BroadcastChan"@ has no 0 reader space leak,
--
-- * @"BroadcastChan"@ has comparable or better performance.
--
-- __Why should I use "BroadcastChan" over various (closable) STM channels?__
--
-- * @"BroadcastChan"@ is single-wakeup,
--
-- * @"BroadcastChan"@ is fair,
--
-- * @"BroadcastChan"@ performs better under contention.
-------------------------------------------------------------------------------
module BroadcastChan (
    -- * Datatypes
      BroadcastChan
    , Direction(..)
    , In
    , Out
    -- * Construction
    , newBroadcastChan
    , newBChanListener
    -- * Basic Operations
    , readBChan
    , writeBChan
    , closeBChan
    , isClosedBChan
    -- * Utility functions
    , foldBChan
    , foldBChanM
    , getBChanContents
    , Action(..)
    , Handler(..)
    , parMapM_
    , parFoldMap
    , parFoldMapM
    ) where

import Control.Exception
    (SomeException(..), mask, throwIO, try, uninterruptibleMask_)
import Control.Monad (liftM)
import Control.Monad.IO.Unlift (MonadUnliftIO(..), UnliftIO(..))
import Data.Foldable as F (Foldable(..), foldlM, forM_)

import BroadcastChan.Extra
import BroadcastChan.Internal

bracketOnError :: MonadUnliftIO m => IO a -> (a -> IO b) -> m c -> m c
bracketOnError before after thing = withRunInIO $ \run -> mask $ \restore -> do
  x <- before
  res1 <- try . restore . run $ thing
  case res1 of
    Left (SomeException exc) -> do
      _ :: Either SomeException b <- try . uninterruptibleMask_ $ after x
      throwIO exc
    Right y -> return y

-- | Map a monadic function over a 'Foldable', processing elements in parallel.
--
-- This function does *NOT* guarantee that elements are processed in a
-- deterministic order!
parMapM_
    :: (F.Foldable f, MonadUnliftIO m)
    => Handler m a
    -- ^ Exception handler
    -> Int
    -- ^ Number of parallel threads to use
    -> (a -> m ())
    -- ^ Function to run in parallel
    -> f a
    -- ^ The 'Foldable' to process in parallel
    -> m ()
parMapM_ hndl threads workFun input = do
    UnliftIO runInIO <- askUnliftIO

    Bracket{allocate,cleanup,action} <- runParallel_
        (mapHandler runInIO hndl)
        threads
        (runInIO . workFun)
        (forM_ input)

    bracketOnError allocate cleanup action

-- | Like 'parMapM_', but folds the individual results into single result
-- value.
--
-- This function does *NOT* guarantee that elements are processed in a
-- deterministic order!
parFoldMap
    :: (F.Foldable f, MonadUnliftIO m)
    => Handler m a
    -- ^ Exception handler
    -> Int
    -- ^ Number of parallel threads to use
    -> (a -> m b)
    -- ^ Function to run in parallel
    -> (r -> b -> r)
    -- ^ Function to fold results with
    -> r
    -- ^ Zero element for the fold
    -> f a
    -- ^ The 'Foldable' to process
    -> m r
parFoldMap hndl threads work f =
  parFoldMapM hndl threads work (\x y -> return (f x y))

-- | Like 'parFoldMap', but uses a monadic fold function.
--
-- This function does *NOT* guarantee that elements are processed in a
-- deterministic order!
parFoldMapM
    :: forall a b f m r
     . (F.Foldable f, MonadUnliftIO m)
    => Handler m a
    -- ^ Exception handler
    -> Int
    -- ^ Number of parallel threads to use
    -> (a -> m b)
    -- ^ Function to run in parallel
    -> (r -> b -> m r)
    -- ^ Monadic function to fold results with
    -> r
    -- ^ Zero element for the fold
    -> f a
    -- ^ The 'Foldable' to process
    -> m r
parFoldMapM hndl threads workFun f z input = do
    UnliftIO runInIO <- askUnliftIO

    Bracket{allocate,cleanup,action} <- runParallel
        (Right f)
        (mapHandler runInIO hndl)
        threads
        (runInIO . workFun)
        body

    bracketOnError allocate cleanup action
  where
    body :: (a -> m ()) -> (a -> m b) -> m r
    body send sendRecv = snd `liftM` foldlM wrappedFoldFun (0, z) input
      where
        wrappedFoldFun :: (Int, r) -> a -> m (Int, r)
        wrappedFoldFun (i, x) a
            | i == threads = liftM (i,) $ sendRecv a >>= f x
            | otherwise = const (i+1, x) `liftM` send a
