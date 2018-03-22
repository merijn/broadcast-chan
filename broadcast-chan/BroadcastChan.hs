{-# LANGUAGE RankNTypes #-}
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

import Control.Monad (liftM)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Foldable as F (Foldable(..), foldlM, forM_)

import BroadcastChan.Internal
import BroadcastChan.Utils

parMapM_
    :: (F.Foldable f, MonadIO m)
    => (forall x . m x -> (x -> m ()) -> (x -> m ()) -> m ())
    -> Handler a
    -> Int
    -> (a -> IO ())
    -> f a
    -> m ()
parMapM_ bracketOnError hndl threads work input =
    runParallel_ bracketOnError (forM_ input) hndl threads work

parFoldMap
    :: (F.Foldable f, MonadIO m)
    => (forall x . m x -> (x -> m ()) -> (x -> m r) -> m r)
    -> Handler a
    -> Int
    -> (a -> IO b)
    -> (r -> b -> r)
    -> r
    -> f a
    -> m r
parFoldMap bracketOnError hndl threads work f =
  parFoldMapM bracketOnError hndl threads work (\x y -> return (f x y))

parFoldMapM
    :: forall a b f m r
     . (F.Foldable f, MonadIO m)
    => (forall x . m x -> (x -> m ()) -> (x -> m r) -> m r)
    -> Handler a
    -> Int
    -> (a -> IO b)
    -> (r -> b -> m r)
    -> r
    -> f a
    -> m r
parFoldMapM bracketOnError hndl threads work f z input =
    runParallel bracketOnError body (Right f) hndl threads work
  where
    body :: (a -> m ()) -> (a -> m b) -> m r
    body send sendRecv = snd `liftM` foldlM wrappedFoldFun (0, z) input
      where
        wrappedFoldFun :: (Int, r) -> a -> m (Int, r)
        wrappedFoldFun (i, x) a
            | i == threads = liftM (i,) $ sendRecv a >>= f x
            | otherwise = const (i+1, x) `liftM` send a
