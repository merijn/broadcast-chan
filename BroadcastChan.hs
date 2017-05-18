{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
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
module BroadcastChan
    ( BroadcastChan
    , Direction(..)
    , In
    , Out
    , newBroadcastChan
    , newBChanListener
    , readBChan
    , writeBChan
    , closeBChan
    , isClosedBChan
    ) where

import Control.Applicative ((<*))
import Control.Concurrent.MVar
import Control.Exception (mask_)

-- | Used with DataKinds as phantom type indicating whether a 'BroadcastChan'
-- value is a read or write end.
data Direction = In  -- ^ Indicates a write 'BroadcastChan'
               | Out -- ^ Indicates a read 'BroadcastChan'

-- | Alias for the 'In' type from the 'Direction' kind, allows users to write
-- the @'BroadcastChan' 'In' a@ type without enabling @DataKinds@.
type In = 'In

-- | Alias for the 'Out' type from the 'Direction' kind, allows users to write
-- the @'BroadcastChan' 'Out' a@ type without enabling @DataKinds@.
type Out = 'Out

-- | The abstract type representing the read or write end of a 'BroadcastChan'.
newtype BroadcastChan (d :: Direction) a = BChan (MVar (Stream a))
    deriving (Eq)

type Stream a = MVar (ChItem a)

data ChItem a = ChItem a {-# UNPACK #-} !(Stream a) | Closed

-- | Creates a new 'BroadcastChan' write end.
newBroadcastChan :: IO (BroadcastChan In a)
newBroadcastChan = do
   hole  <- newEmptyMVar
   writeVar <- newMVar hole
   return (BChan writeVar)

-- | Close a 'BroadcastChan', disallowing further writes. Returns 'True' if the
-- 'BroadcastChan' was closed. Returns 'False' if the 'BroadcastChan' was
-- __already__ closed.
closeBChan :: BroadcastChan In a -> IO Bool
closeBChan (BChan writeVar) = mask_ $ do
    old_hole <- takeMVar writeVar
    -- old_hole is always empty unless the channel was already closed
    tryPutMVar old_hole Closed <* putMVar writeVar old_hole

-- | Check whether a 'BroadcastChan' is closed. 'True' means it's closed,
-- 'False' means it's writable. However:
--
-- __Beware of TOC-TOU races__: It is possible for a 'BroadcastChan' to be
-- closed by another thread. If multiple threads use the same 'BroadcastChan' a
-- 'closeBChan' from another thread might result in the channel being closed
-- right after 'isClosedBChan' returns.
isClosedBChan :: BroadcastChan In a -> IO Bool
#if MIN_VERSION_base(4,7,0)
isClosedBChan (BChan writeVar) = do
    old_hole <- readMVar writeVar
    val <- tryReadMVar old_hole
#else
isClosedBChan (BChan writeVar) = mask_ $ do
    old_hole <- takeMVar writeVar
    val <- tryTakeMVar old_hole
    case val of
        Just x -> putMVar old_hole x
        Nothing -> return ()
    putMVar writeVar old_hole
#endif
    case val of
        Just Closed -> return True
        _ -> return False

-- | Write a value to write end of a 'BroadcastChan'. Any messages written
-- while there are no live read ends are dropped on the floor and can be
-- immediately garbage collected, thus avoiding space leaks.
--
-- The return value indicates whether the write succeeded, i.e., 'True' if the
-- message was written, 'False' is the channel is closed.
-- See @BroadcastChan.Throw.@'BroadcastChan.Throw.writeBChan' for an
-- exception throwing variant.
writeBChan :: BroadcastChan In a -> a -> IO Bool
writeBChan (BChan writeVar) val = do
  new_hole <- newEmptyMVar
  mask_ $ do
    old_hole <- takeMVar writeVar
    -- old_hole is only full if the channel was previously closed
    empty <- tryPutMVar old_hole (ChItem val new_hole)
    if empty
       then putMVar writeVar new_hole
       else putMVar writeVar old_hole
    return empty
{-# INLINE writeBChan #-}

-- | Read the next value from the read end of a 'BroadcastChan'. Returns
-- 'Nothing' if the 'BroadcastChan' is closed and empty.
-- See @BroadcastChan.Throw.@'BroadcastChan.Throw.readBChan' for an exception
-- throwing variant.
readBChan :: BroadcastChan Out a -> IO (Maybe a)
readBChan (BChan readVar) = do
  modifyMVarMasked readVar $ \read_end -> do -- Note [modifyMVarMasked]
    -- Use readMVar here, not takeMVar,
    -- else newBChanListener doesn't work
    result <- readMVar read_end
    case result of
        ChItem val new_read_end -> return (new_read_end, Just val)
        Closed -> return (read_end, Nothing)
{-# INLINE readBChan #-}

-- Note [modifyMVarMasked]
-- This prevents a theoretical deadlock if an asynchronous exception
-- happens during the readMVar while the MVar is empty.  In that case
-- the read_end MVar will be left empty, and subsequent readers will
-- deadlock.  Using modifyMVarMasked prevents this.  The deadlock can
-- be reproduced, but only by expanding readMVar and inserting an
-- artificial yield between its takeMVar and putMVar operations.

-- | Create a new read end for a 'BroadcastChan'. Will receive all messages
-- written to the channel __after__ this read end is created.
newBChanListener :: BroadcastChan In a -> IO (BroadcastChan Out a)
newBChanListener (BChan writeVar) = do
   hole       <- readMVar writeVar
   newReadVar <- newMVar hole
   return (BChan newReadVar)

#if !MIN_VERSION_base(4,6,0)
{-# INLINE modifyMVarMasked #-}
modifyMVarMasked :: MVar a -> (a -> IO (a,b)) -> IO b
modifyMVarMasked m io =
  mask_ $ do
    a      <- takeMVar m
    (a',b) <- (io a >>= evaluate) `onException` putMVar m a
    putMVar m a'
    return b
#endif
