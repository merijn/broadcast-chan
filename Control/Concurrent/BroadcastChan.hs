{-# LANGUAGE AutoDeriveTypeable #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE Safe #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  Contro.Concurrent.BroadcastChan
-- Copyright   :  (C) 2014 Merijn Verstraaten
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Merijn Verstraaten <merijn@inconsistent.nl>
-- Stability   :  experimental
-- Portability :  haha
--
-- A variation of "Control.Concurrent.Chan" from base, which allows to the easy
-- creation of broadcast channels without the space-leaks that may arise from
-- using 'Control.Concurrent.Chan.dupChan'.
--
-- The 'Control.Concurrent.Chan.Chan' type from "Control.Concurrent.Chan"
-- consists of both a read and write end. This presents a problem when one
-- wants to have a broadcast channel that, at times, has zero listeners. To
-- write to a 'Control.Concurrent.Chan.Chan' there must always be a read end
-- and this read end will hold ALL messages alive until read.
--
-- The simple solution applied in this module is to separate read and write
-- ends. As a result, any messages written to the write end can be immediately
-- garbage collected if there are no active read ends, avoding space leaks.
-------------------------------------------------------------------------------
module Control.Concurrent.BroadcastChan
    ( BChanError
    , BroadcastChan
    , In
    , Out
    , newBroadcastChan
    , closeBChan
    , isClosedBChan
    , writeBChan
    , writeBChan_
    , readBChan
    , readBChan_
    , newBChanListener
    ) where

import Control.Monad (when)
import Control.Concurrent.MVar
import Control.Exception (Exception, mask_, throwIO)
import GHC.Generics (Generic)

-- | Exception type for 'BroadcastChan' operations.
data BChanError
    = WriteFailed   -- ^ Attempted to write to closed 'BroadcastChan'
    | ReadFailed    -- ^ Attempted to read from closed 'BroadcastChan'
    deriving (Eq, Read, Show)

instance Exception BChanError

data Direction = In | Out

-- | Alias for the 'In' type from the 'Direction' kind, allows users to write
-- the 'BroadcastChan In a' type without enabling DataKinds.
type In = 'In
-- | Alias for the 'Out' type from the 'Direction' kind, allows users to write
-- the 'BroadcastChan Out a' type without enabling DataKinds.
type Out = 'Out

-- | The abstract type representing the read or write end of a 'BroadcastChan'.
newtype BroadcastChan (d :: Direction) a = BChan (MVar (Stream a))
    deriving (Eq, Generic)

type Stream a = MVar (ChItem a)

data ChItem a = ChItem a {-# UNPACK #-} !(Stream a) | Closed

-- | Creates a new 'BroadcastChan' write end.
newBroadcastChan :: IO (BroadcastChan In a)
newBroadcastChan = do
   hole  <- newEmptyMVar
   writeVar <- newMVar hole
   return (BChan writeVar)

-- | Close a 'BroadcastChan', disallowing further writes. Return value
-- indicates whether the 'BroadcastChan' was already closed.
closeBChan :: BroadcastChan In a -> IO Bool
closeBChan (BChan writeVar) = mask_ $ do
    old_hole <- takeMVar writeVar
    tryPutMVar old_hole Closed <* putMVar writeVar old_hole

-- | Check whether a 'BroadcastChan' is closed. Beware of TOC-TOU races,
-- it is possible for a 'BroadcastChan' to be closed by another thread. If
-- multiple threads use the same 'BroadcastChan' a 'closeBChan' from another
-- thread might cause writes to fail even after 'isClosedBChan' returns 'True'.
isClosedBChan :: BroadcastChan In a -> IO Bool
isClosedBChan (BChan writeVar) = mask_ $ do
    old_hole <- takeMVar writeVar
    val <- tryReadMVar old_hole
    case val of
        Just Closed -> return True
        _ -> return False

-- | Write a value to write end of a 'BroadcastChan'. Any messages written
-- while there are no live read ends can be immediately garbage collected, thus
-- avoiding space leaks.
--
-- The return value indicates whether the write succeeded or failed (due to a
-- closed 'BroadcastChan'). See 'writeBChan_' for an exception throwing
-- variant.
writeBChan :: BroadcastChan In a -> a -> IO Bool
writeBChan (BChan writeVar) val = do
  new_hole <- newEmptyMVar
  mask_ $ do
    old_hole <- takeMVar writeVar
    empty <- tryPutMVar old_hole (ChItem val new_hole)
    if empty
       then putMVar writeVar new_hole
       else putMVar writeVar old_hole
    return empty

-- | Like 'writeBChan', but throws a 'WriteFailed' exception when writing to
-- closed 'BroadcastChan'.
writeBChan_ :: BroadcastChan In a -> a -> IO ()
writeBChan_ ch val = do
    success <- writeBChan ch val
    when (not success) $ throwIO WriteFailed

-- | Read the next value from the read end of a 'BroadcastChan'. Returns
-- 'Nothing' if the 'BroadcastChan' is closed and empty. See 'readBChan_' for
-- an exception throwing variant.
readBChan :: BroadcastChan Out a -> IO (Maybe a)
readBChan (BChan readVar) = do
  modifyMVarMasked readVar $ \read_end -> do -- Note [modifyMVarMasked]
    -- Use readMVar here, not takeMVar,
    -- else newBChanListener doesn't work
    result <- readMVar read_end
    case result of
        (ChItem val new_read_end) -> return (new_read_end, Just val)
        Closed -> return (read_end, Nothing)

-- | Like 'readBChan', but throws a 'ReadFailed' exception when reading from a
-- closed and empty 'BroadcastChan'.
readBChan_ :: BroadcastChan Out a -> IO a
readBChan_ ch = do
    result <- readBChan ch
    case result of
        Nothing -> throwIO ReadFailed
        Just x -> return x

-- Note [modifyMVarMasked]
-- This prevents a theoretical deadlock if an asynchronous exception
-- happens during the readMVar while the MVar is empty.  In that case
-- the read_end MVar will be left empty, and subsequent readers will
-- deadlock.  Using modifyMVarMasked prevents this.  The deadlock can
-- be reproduced, but only by expanding readMVar and inserting an
-- artificial yield between its takeMVar and putMVar operations.

-- | Create a new read end for a 'BroadcastChan'. Will receive all messages
-- written to the channel's write end after the read end's creation.
newBChanListener :: BroadcastChan In a -> IO (BroadcastChan Out a)
newBChanListener (BChan writeVar) = do
   hole       <- readMVar writeVar
   newReadVar <- newMVar hole
   return (BChan newReadVar)
