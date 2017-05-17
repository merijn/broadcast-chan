{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  BroadcastChan
-- Copyright   :  (C) 2014-2017 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- Re-export of "Broadcast" that replaces 'writeBChan' and 'readBChan' with
-- versions that throw an exception, rather than returning results that the
-- user has to inspect to check for success.
-------------------------------------------------------------------------------
module BroadcastChan.Throw
    ( BChanError(..)
    , readBChan
    , writeBChan
    , module BroadcastChan
    ) where

import Control.Monad (when)
import Control.Exception (Exception, throwIO)
import Data.Typeable (Typeable)

import BroadcastChan hiding (writeBChan, readBChan)
import qualified BroadcastChan as Internal

-- | Exception type for 'BroadcastChan' operations.
data BChanError
    = WriteFailed   -- ^ Attempted to write to closed 'BroadcastChan'
    | ReadFailed    -- ^ Attempted to read from an empty closed 'BroadcastChan'
    deriving (Eq, Read, Show, Typeable)

instance Exception BChanError

-- | Like 'Internal.readBChan', but throws a 'ReadFailed' exception when
-- reading from a closed and empty 'BroadcastChan'.
readBChan :: BroadcastChan Out a -> IO a
readBChan ch = do
    result <- Internal.readBChan ch
    case result of
        Nothing -> throwIO ReadFailed
        Just x -> return x
{-# INLINE readBChan #-}

-- | Like 'Internal.writeBChan', but throws a 'WriteFailed' exception when
-- writing to closed 'BroadcastChan'.
writeBChan :: BroadcastChan In a -> a -> IO ()
writeBChan ch val = do
    success <- Internal.writeBChan ch val
    when (not success) $ throwIO WriteFailed
{-# INLINE writeBChan #-}
