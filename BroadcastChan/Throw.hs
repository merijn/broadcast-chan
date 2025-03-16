{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan.Throw
-- Copyright   :  (C) 2014-2022 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- This module is identical to "BroadcastChan", but with
-- @BroadcastChan.@'BroadcastChan.writeBChan' and
-- @BroadcastChan.@'BroadcastChan.readBChan' replaced with versions that throw
-- an exception, rather than returning results that the user has to inspect to
-- check for success.
-------------------------------------------------------------------------------
module BroadcastChan.Throw
    ( BChanError(..)
    , readBChan
    , tryReadBChan
    , writeBChan
    -- * Re-exports from "BroadcastChan"
    -- ** Datatypes
    , BroadcastChan
    , Direction(..)
    , In
    , Out
    -- ** Construction
    , newBroadcastChan
    , newBChanListener
    -- ** Basic Operations
    , closeBChan
    , isClosedBChan
    , getBChanContents
    -- ** Parallel processing
    , Action(..)
    , Handler(..)
    , parMapM_
    , parFoldMap
    , parFoldMapM
    -- ** Foldl combinators
    -- | Combinators for use with Tekmo's @foldl@ package.
    , foldBChan
    , foldBChanM
    ) where

import Control.Monad (when)
import Control.Monad.IO.Unlift (MonadIO(..))
import Control.Exception (Exception, throwIO)

import BroadcastChan hiding (writeBChan, readBChan, tryReadBChan)
import qualified BroadcastChan as Internal

-- | Exception type for 'BroadcastChan' operations.
--
-- @since 0.2.0
data BChanError
    = WriteFailed   -- ^ Attempted to write to closed 'BroadcastChan'
    | ReadFailed    -- ^ Attempted to read from an empty closed 'BroadcastChan'
    deriving (Eq, Read, Show)

instance Exception BChanError

-- | Like 'Internal.readBChan', but throws a 'ReadFailed' exception when
-- reading from a closed and empty 'BroadcastChan'.
--
-- @since 0.2.0
readBChan :: MonadIO m => BroadcastChan Out a -> m a
readBChan ch = do
    result <- Internal.readBChan ch
    case result of
        Nothing -> liftIO $ throwIO ReadFailed
        Just x -> return x
{-# INLINE readBChan #-}
--
-- | Like 'Internal.tryReadBChan', but throws a 'ReadFailed' exception when
-- reading from a closed and empty 'BroadcastChan'.
--
-- @since 0.3.0
tryReadBChan :: MonadIO m => BroadcastChan Out a -> m (Maybe a)
tryReadBChan ch = do
    result <- Internal.tryReadBChan ch
    case result of
        Nothing -> return Nothing
        Just Nothing -> liftIO $ throwIO ReadFailed
        Just v -> return v
{-# INLINE tryReadBChan #-}

-- | Like 'Internal.writeBChan', but throws a 'WriteFailed' exception when
-- writing to closed 'BroadcastChan'.
--
-- @since 0.2.0
writeBChan :: MonadIO m => BroadcastChan In a -> a -> m ()
writeBChan ch val = do
    success <- Internal.writeBChan ch val
    when (not success) . liftIO $ throwIO WriteFailed
{-# INLINE writeBChan #-}
